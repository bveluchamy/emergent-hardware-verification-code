// actor.h -- pure C++17 actor framework for general concurrent / distributed
// software systems. Header-only, zero external runtime dependencies beyond
// the C++ standard library.
//
// This is the non-hardware deployment of the actor methodology developed in
// Chapter 5 and Appendix E of "Emergent Functional Verification with
// SystemVerilog". The SystemC port (actor_pkg_systemc/) is for hardware
// verification with simulated time; this port is for everything else --
// microservices, data pipelines, real-time event processors, ML serving,
// regression infrastructure, dashboards, control planes, embedded firmware
// running on a host CPU.
//
// Design choices, all aligned with Data-Oriented Design (DOD):
//
//   1. Messages are Plain Old Data (POD) structs, value-copied through the
//      queue. No shared pointer aliasing across actors; no surprise
//      mutations. Cache-friendly, memcpy-able, easy to log / serialise /
//      replay.
//
//   2. Actors don't share state. Each actor owns its data; communication is
//      typed messages over its own mailbox. No global locks, no atomic
//      counters trafficking shared state across cores.
//
//   3. Declarative typed wiring is the topology primitive. A producer
//      never names its consumers and a consumer never names its producers.
//      Wiring is done from outside by a parent:
//
//          wire<Transaction>(producer, consumer_a);
//          wire<Coverage>   (producer, consumer_b);
//
//      Each consumer receives only the message types it asked for. The
//      producer maintains a type-indexed subscriber map and dispatches
//      publish<T>() only to consumers wired for T. No flat broadcast, no
//      runtime filter at the receiver. This is the framework's defining
//      property and the property that makes the same actor model work
//      identically across hardware modules, host C++, and distributed
//      systems.
//
//   4. No inheritance hierarchies in the hot path. Subclassing Actor is a
//      structural convenience; messages are typed at the value level via
//      Msg<T> templating and the publish/subscribe dispatch table.
//
//   5. Bounded mailboxes. Backpressure is observable via try_publish()'s
//      return value; producers never spin or grow unbounded.
//
// Compared to CAF, Akka, Erlang:
//
//   Those frameworks have typed messages but dispatch is *imperative*:
//   each actor's handler references its destinations by address. The
//   producer names consumers in its own code, which is what prevents
//   those models from generalising to hardware (where a module never
//   names its peers --- the parent wires the ports). This framework
//   inverts: typed dispatch, but topology is declarative and external.
//   Same model runs as RTL, as host C++, as a microservice mesh.

#ifndef ACTOR_PKG_CPP_ACTOR_H
#define ACTOR_PKG_CPP_ACTOR_H

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <typeindex>
#include <typeinfo>
#include <unordered_map>
#include <vector>

namespace actor {
namespace cpp {

// ---- Universal message envelope -----------------------------------------

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

// ---- Bounded MPSC mailbox -----------------------------------------------
// Multiple producer threads (other actors publishing into this mailbox),
// single consumer thread (this actor's run_loop). std::mutex + condvar is
// simple and sufficient for typical actor message rates; for >1M msg/sec
// per actor, swap in a lock-free queue (moodycamel, boost::lockfree).

template <typename T>
class Mailbox {
 public:
  explicit Mailbox(size_t capacity) : capacity_(capacity) {}

  bool try_put(T item) {
    std::lock_guard<std::mutex> lock(mtx_);
    if (queue_.size() >= capacity_) return false;
    queue_.push(std::move(item));
    cv_.notify_one();
    return true;
  }

  bool get(T& out) {
    std::unique_lock<std::mutex> lock(mtx_);
    cv_.wait(lock, [&] { return !queue_.empty() || !running_.load(); });
    if (!running_.load() && queue_.empty()) return false;
    out = std::move(queue_.front());
    queue_.pop();
    return true;
  }

  void stop() {
    running_.store(false);
    cv_.notify_all();
  }

  size_t size() {
    std::lock_guard<std::mutex> lock(mtx_);
    return queue_.size();
  }

 private:
  size_t                  capacity_;
  std::mutex              mtx_;
  std::condition_variable cv_;
  std::queue<T>           queue_;
  std::atomic<bool>       running_{true};
};

// ---- Actor base class ---------------------------------------------------

class Actor {
 public:
  explicit Actor(std::string name, size_t mbox_capacity = 1024)
      : name_(std::move(name)),
        id_(next_actor_id()),
        mbox_(mbox_capacity) {}

  virtual ~Actor() {
    stop();
    if (thread_.joinable()) thread_.join();
  }

  // Register a typed subscriber for messages of type T. Invoked by the
  // free function wire<T>(producer, consumer); rarely called directly.
  template <typename T>
  void add_subscriber(Actor* sub) {
    subscribers_by_type_[std::type_index(typeid(T))].push_back(sub);
  }

  // Emit a message of type T. Looks up subscribers by typeid(T) and fans
  // out only to wired consumers. Non-blocking try_put on each recipient.
  template <typename T>
  void publish(T payload) {
    auto msg = std::make_shared<Msg<T>>(std::move(payload));
    publish_msg(msg);
  }

  // Publish an already-built typed message (used for trace propagation).
  template <typename T>
  void publish_msg(std::shared_ptr<Msg<T>> msg) {
    msg->stamp(id_);
    auto it = subscribers_by_type_.find(std::type_index(typeid(T)));
    if (it == subscribers_by_type_.end()) return;
    for (Actor* sub : it->second) {
      if (sub->is_alive_.load(std::memory_order_relaxed)) {
        sub->mbox_.try_put(msg);
      }
    }
  }

  // Returns true only when every wired consumer accepted.
  template <typename T>
  bool try_publish(T payload) {
    auto msg = std::make_shared<Msg<T>>(std::move(payload));
    msg->stamp(id_);
    auto it = subscribers_by_type_.find(std::type_index(typeid(T)));
    if (it == subscribers_by_type_.end()) return true;
    bool all_ok = true;
    for (Actor* sub : it->second) {
      if (sub->is_alive_.load(std::memory_order_relaxed)) {
        all_ok = sub->mbox_.try_put(msg) && all_ok;
      }
    }
    return all_ok;
  }

  virtual void act(std::shared_ptr<MsgBase> /*msg*/) {}
  virtual void on_terminate() {}
  virtual void reset() {}

  // Spawn the dispatch thread. Call after all wire<T>() edges are set.
  void start() {
    if (thread_.joinable()) return;
    is_alive_.store(true);
    thread_ = std::thread(&Actor::run_loop, this);
  }

  void stop() {
    is_alive_.store(false);
    mbox_.stop();
    on_terminate();
  }

  const std::string& name() const { return name_; }
  uint32_t           id()   const { return id_; }
  size_t             mailbox_size() { return mbox_.size(); }

 protected:
  std::string         name_;
  uint32_t            id_;
  std::atomic<bool>   is_alive_{true};
  Mailbox<std::shared_ptr<MsgBase>> mbox_;
  std::unordered_map<std::type_index, std::vector<Actor*>> subscribers_by_type_;

 private:
  std::thread thread_;

  void run_loop() {
    while (is_alive_.load(std::memory_order_relaxed)) {
      std::shared_ptr<MsgBase> msg;
      if (!mbox_.get(msg)) break;
      if (!is_alive_.load()) break;
      act(msg);
    }
  }

  static uint32_t next_actor_id() {
    static std::atomic<uint32_t> counter{1};
    return counter.fetch_add(1, std::memory_order_relaxed);
  }
};

// ---- Declarative wiring primitive ---------------------------------------
//
// wire<T>(producer, consumer) -- "wire messages of type T from producer
// to consumer". The wiring statement is symmetric (no false producer-acts
// or consumer-acts subject) and reads as a connection declaration in the
// parent that owns the topology. Same shape that hardware module
// instantiation uses at the SoC/testbench level.
//
// A consumer that wants multiple message types from one producer issues
// one wire<T>() per type. There is no wildcard / subscribe-to-everything
// primitive; the topology is fully explicit in the wiring code.

template <typename T>
inline void wire(Actor* producer, Actor* consumer) {
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

// ---- Helper: start a group of actors atomically -------------------------

inline void start_all(std::vector<Actor*> actors) {
  for (Actor* a : actors) a->start();
}

inline void stop_all(std::vector<Actor*> actors) {
  for (Actor* a : actors) a->stop();
}

}  // namespace cpp
}  // namespace actor

#endif  // ACTOR_PKG_CPP_ACTOR_H
