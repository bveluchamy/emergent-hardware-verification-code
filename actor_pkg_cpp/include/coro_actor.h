// coro_actor.h -- C++20 coroutine-based actor framework.
//
// Each actor is a stackless coroutine. The actor's run() method is a
// long-lived coroutine that loops on `co_await mbox.recv()` -- when the
// mailbox is empty, the coroutine suspends; when a typed message arrives,
// the scheduler resumes it. No std::thread per actor; thousands or
// millions of actors share a small pool of OS worker threads (M:N green
// threads).
//
// Same declarative-typed-wiring property as the basic tier: a producer
// never names its consumers, a consumer never names its producers,
// topology is wired externally with wire<T>() calls. The coroutine
// machinery is a scheduling implementation detail.
//
//     wire<Ping>(producer, consumer);
//     // consumer.run() will see only Pings from producer
//     auto msg = co_await mbox_.recv();
//     if (auto p = std::dynamic_pointer_cast<Msg<Ping>>(msg)) { ... }
//
// Memory cost per actor: one heap-allocated coroutine frame, typically
// 100-300 bytes. 100,000 actors fit in ~25 MB versus ~800 MB for one
// std::thread per actor (8 KB stack each).
//
// This is the same execution model Erlang's BEAM, Go goroutines, and
// Java Project Loom virtual threads use. The actor methodology happens
// to match this model perfectly: each actor is conceptually a process,
// suspending on its mailbox, resumed by the scheduler when work arrives.

#ifndef ACTOR_PKG_CPP_CORO_ACTOR_H
#define ACTOR_PKG_CPP_CORO_ACTOR_H

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <coroutine>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <typeindex>
#include <typeinfo>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

namespace actor {
namespace coro {

// Forward-declare the scheduler so Task and Mailbox can resume coroutines.
class Scheduler;

// ---- Universal message envelope -----------------------------------------
// Shares the same metadata model as actor::cpp::MsgBase --- trace_id,
// parent_span, timestamp_ns, sender_id --- so OpenTelemetry-style cross-
// actor tracing works without retrofit and dual-tier topologies (some
// actors basic, some coroutine) interoperate.

struct MsgBase {
  uint64_t           id            = 0;
  uint64_t           trace_id      = 0;
  uint64_t           parent_span   = 0;
  uint64_t           timestamp_ns  = 0;
  uint32_t           sender_id     = 0;

  virtual ~MsgBase() = default;
  virtual std::string type_name() const = 0;

  void stamp(uint32_t sender) {
    sender_id = sender;
    timestamp_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    if (trace_id == 0) trace_id = next_trace_id();
  }

 private:
  static uint64_t next_trace_id() {
    static std::atomic<uint64_t> counter{1};
    return counter.fetch_add(1, std::memory_order_relaxed);
  }
};

template <typename T>
struct Msg : MsgBase {
  T payload;
  explicit Msg(T p) : payload(std::move(p)) {}
  std::string type_name() const override { return typeid(T).name(); }

  static std::shared_ptr<Msg<T>> from_parent(T p, const MsgBase& parent) {
    auto m = std::make_shared<Msg<T>>(std::move(p));
    m->trace_id    = parent.trace_id;
    m->parent_span = parent.id;
    return m;
  }
};

// ---- Task<T> ------------------------------------------------------------
// Return type for coroutine functions. The actor's run() method returns
// Task<void>. Coroutines start suspended; we explicitly schedule the
// initial resumption.

template <typename T = void>
struct Task {
  struct promise_type {
    Task get_return_object() {
      return Task{std::coroutine_handle<promise_type>::from_promise(*this)};
    }
    std::suspend_always initial_suspend() noexcept { return {}; }
    std::suspend_always final_suspend()   noexcept { return {}; }
    void return_void() {}
    void unhandled_exception() { std::terminate(); }
  };

  using handle_type = std::coroutine_handle<promise_type>;
  handle_type handle{};

  Task() = default;
  explicit Task(handle_type h) : handle(h) {}

  Task(const Task&)            = delete;
  Task& operator=(const Task&) = delete;

  Task(Task&& other) noexcept : handle(other.handle) { other.handle = {}; }
  Task& operator=(Task&& other) noexcept {
    if (handle) handle.destroy();
    handle = other.handle;
    other.handle = {};
    return *this;
  }

  ~Task() {
    if (handle) handle.destroy();
  }

  std::coroutine_handle<> raw() const { return handle; }
};

// ---- Scheduler ----------------------------------------------------------
// M:N scheduler. N OS worker threads pull from a shared ready queue,
// resuming coroutines one at a time. Each call to .resume() runs one
// coroutine until its next co_await suspension or completion.

class Scheduler {
 public:
  static Scheduler& instance() {
    static Scheduler s;
    return s;
  }

  void start(size_t n_threads = std::thread::hardware_concurrency()) {
    if (started_) return;
    started_ = true;
    if (n_threads == 0) n_threads = 1;
    running_.store(true, std::memory_order_release);
    for (size_t i = 0; i < n_threads; ++i) {
      workers_.emplace_back([this] { worker_loop(); });
    }
  }

  void stop() {
    running_.store(false, std::memory_order_release);
    cv_.notify_all();
    for (auto& t : workers_) if (t.joinable()) t.join();
    workers_.clear();
    started_ = false;
  }

  void schedule(std::coroutine_handle<> h) {
    {
      std::lock_guard<std::mutex> lock(mtx_);
      ready_.push_back(h);
    }
    cv_.notify_one();
  }

  size_t threads() const { return workers_.size(); }

 private:
  Scheduler() = default;
  ~Scheduler() { stop(); }

  bool                                   started_ = false;
  std::vector<std::thread>               workers_;
  std::mutex                             mtx_;
  std::condition_variable                cv_;
  std::deque<std::coroutine_handle<>>    ready_;
  std::atomic<bool>                      running_{false};

  void worker_loop() {
    while (running_.load(std::memory_order_acquire)) {
      std::coroutine_handle<> h{};
      {
        std::unique_lock<std::mutex> lock(mtx_);
        cv_.wait(lock, [&] {
          return !ready_.empty() ||
                 !running_.load(std::memory_order_acquire);
        });
        if (!running_.load(std::memory_order_acquire) && ready_.empty()) return;
        h = ready_.front();
        ready_.pop_front();
      }
      if (h && !h.done()) h.resume();
    }
  }
};

// ---- Mailbox<T> ---------------------------------------------------------
// Awaitable FIFO. `co_await mbox.recv()` returns the next message, suspending
// if empty. CoroActor's mbox_ is parameterised by shared_ptr<MsgBase> so the
// type-indexed publish/dispatch path uses a single mailbox shape, and the
// consumer's run() coroutine casts to whichever typed messages it asked for
// via wire<T>(). Direct-publisher producers may still use a typed Mailbox<T>
// where the higher overhead of dynamic_cast is unwanted.

template <typename T>
class Mailbox {
 public:
  void put(T value) {
    std::coroutine_handle<> to_resume{};
    {
      std::lock_guard<std::mutex> lock(mtx_);
      q_.push_back(std::move(value));
      if (waiter_) {
        to_resume = waiter_;
        waiter_   = {};
      }
    }
    if (to_resume) {
      Scheduler::instance().schedule(to_resume);
    }
  }

  size_t size() {
    std::lock_guard<std::mutex> lock(mtx_);
    return q_.size();
  }

  struct Awaiter {
    Mailbox&            mbox;
    std::optional<T>    captured;

    bool await_ready() {
      std::lock_guard<std::mutex> lock(mbox.mtx_);
      if (!mbox.q_.empty()) {
        captured = std::move(mbox.q_.front());
        mbox.q_.pop_front();
        return true;
      }
      return false;
    }

    bool await_suspend(std::coroutine_handle<> h) {
      std::lock_guard<std::mutex> lock(mbox.mtx_);
      if (!mbox.q_.empty()) {
        captured = std::move(mbox.q_.front());
        mbox.q_.pop_front();
        return false;
      }
      mbox.waiter_ = h;
      return true;
    }

    T await_resume() {
      if (captured) {
        return std::move(*captured);
      }
      std::lock_guard<std::mutex> lock(mbox.mtx_);
      T value = std::move(mbox.q_.front());
      mbox.q_.pop_front();
      return value;
    }
  };

  Awaiter recv() { return Awaiter{*this, std::nullopt}; }

 private:
  std::mutex                  mtx_;
  std::deque<T>               q_;
  std::coroutine_handle<>     waiter_{};
};

// ---- CoroActor base class -----------------------------------------------
// Subclasses override run() with their main coroutine, which co_awaits
// mbox_ for an envelope (shared_ptr<MsgBase>) and dispatches by type to
// the handlers it cares about. wire<T>(producer, consumer) called from
// outside registers the consumer as a typed subscriber on the producer;
// publish<T>(value) on the producer fans out only to wired consumers.

class CoroActor {
 public:
  CoroActor()          = default;
  virtual ~CoroActor() = default;

  CoroActor(const CoroActor&)            = delete;
  CoroActor& operator=(const CoroActor&) = delete;

  // The mailbox where typed-dispatched messages arrive. Subclass's run()
  // co_awaits this and dispatches by dynamic_cast<Msg<T>*>.
  Mailbox<std::shared_ptr<MsgBase>> mbox_;

  // Subscribers wired for specific message types.
  std::unordered_map<std::type_index, std::vector<CoroActor*>> subscribers_by_type_;

  uint32_t id() const { return id_; }

  // Register a typed subscriber. Called by wire<T>().
  template <typename T>
  void add_subscriber(CoroActor* sub) {
    subscribers_by_type_[std::type_index(typeid(T))].push_back(sub);
  }

  // Emit a message of type T. Routes only to subscribers wired for T.
  template <typename T>
  void publish(T payload) {
    auto msg = std::make_shared<Msg<T>>(std::move(payload));
    publish_msg(msg);
  }

  template <typename T>
  void publish_msg(std::shared_ptr<Msg<T>> msg) {
    msg->stamp(id_);
    auto it = subscribers_by_type_.find(std::type_index(typeid(T)));
    if (it == subscribers_by_type_.end()) return;
    for (auto* sub : it->second) {
      if (sub->alive()) sub->mbox_.put(msg);
    }
  }

  virtual Task<void> run() = 0;

  void start() {
    task_ = run();
    if (task_.handle) {
      Scheduler::instance().schedule(task_.handle);
    }
  }

  void stop() {
    alive_.store(false, std::memory_order_release);
  }

  bool alive() const {
    return alive_.load(std::memory_order_acquire);
  }

 protected:
  Task<void>          task_;
  std::atomic<bool>   alive_{true};
  uint32_t            id_{next_id()};

 private:
  static uint32_t next_id() {
    static std::atomic<uint32_t> counter{1};
    return counter.fetch_add(1, std::memory_order_relaxed);
  }
};

// ---- Declarative wiring primitive ---------------------------------------
//
// wire<T>(producer, consumer) -- one typed edge. A consumer that wants
// multiple message types from one producer issues one wire<T>() per
// type. No wildcard primitive; topology is fully explicit in the
// wiring code.

template <typename T>
inline void wire(CoroActor* producer, CoroActor* consumer) {
  producer->template add_subscriber<T>(consumer);
}

// ---- PUBLISH helpers ----------------------------------------------------

template <typename T>
inline std::shared_ptr<Msg<T>> make_msg(T payload) {
  return std::make_shared<Msg<T>>(std::move(payload));
}

template <typename T>
inline std::shared_ptr<Msg<T>> make_traced_msg(T payload, const MsgBase& parent) {
  return Msg<T>::from_parent(std::move(payload), parent);
}

}  // namespace coro
}  // namespace actor

#endif  // ACTOR_PKG_CPP_CORO_ACTOR_H
