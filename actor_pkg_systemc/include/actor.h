// actor.h -- C++/SystemC parallel implementation of the actor framework.
//
// Mirrors the SystemVerilog actor_pkg API:
//
//   SystemVerilog                          SystemC C++
//   ------------                           -----------
//   class Actor                            class Actor : public sc_module
//   mailbox #(MsgBase) mbox                sc_fifo<std::shared_ptr<MsgBase>> mbox
//   forever begin mbox.get(msg); ... end   SC_THREAD(run) reading from mbox
//   fork begin run() ... end join_none     SC_THREAD spawn at construction
//   `WIRE(producer, T, sub)                wire<T>(producer, sub)
//   publish(msg) -> try_put by type        publish(msg) -> nb_write by type
//   `PUBLISH macro                         PUBLISH() helper template
//
// The SystemC kernel handles concurrency, timing, and scheduling natively;
// no --timing flag, no V3TSP bug, no coroutine overhead. The same actor
// methodology runs at full speed on any host with SystemC support.

#ifndef ACTOR_PKG_SYSTEMC_ACTOR_H
#define ACTOR_PKG_SYSTEMC_ACTOR_H

#include <systemc.h>
#include <atomic>
#include <memory>
#include <string>
#include <typeinfo>
#include <unordered_map>
#include <vector>

namespace actor {

// ---- MsgBase -------------------------------------------------------------
// Universal message envelope carrying lineage and timing metadata. Every
// actor publication is a shared_ptr<MsgBase>; the typed payload lives in
// the Msg<T> subclass. Match for SV's MsgBase + Msg#(T).

struct MsgBase {
  uint64_t           id            = 0;
  uint64_t           trace_id      = 0;
  uint64_t           parent_span   = 0;
  sc_time            timestamp     = SC_ZERO_TIME;
  uint32_t           sender_id     = 0;

  virtual ~MsgBase() = default;
  virtual std::string type_name() const = 0;

  // Stamp lineage at publish time. Trace ID is allocated lazily.
  void stamp(uint32_t sender) {
    sender_id = sender;
    timestamp = sc_time_stamp();
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

  // Ergonomic constructor preserving lineage from a parent message.
  static std::shared_ptr<Msg<T>> from_parent(T p, const MsgBase& parent) {
    auto m = std::make_shared<Msg<T>>(std::move(p));
    m->trace_id    = parent.trace_id;
    m->parent_span = parent.id;
    return m;
  }
};

// ---- Actor base class ----------------------------------------------------
// Each Actor is an sc_module with a single typed mailbox (sc_fifo) that an
// SC_THREAD drains by calling act() for each received message.
//
// Subclassing pattern:
//
//   class HelloActor : public actor::Actor {
//    public:
//     SC_HAS_PROCESS(HelloActor);
//     HelloActor(sc_module_name name) : Actor(name) {}
//     void act(std::shared_ptr<actor::MsgBase> m) override {
//       // handle inbound message; optionally publish() to subscribers
//     }
//   };

class Actor : public sc_module {
 public:
  sc_fifo<std::shared_ptr<MsgBase>>  mbox;
  std::unordered_map<std::string, std::vector<Actor*>>  subscribers_by_type;
  std::string                        actor_name;
  uint32_t                           actor_id;
  std::atomic<bool>                  is_alive{true};

  explicit Actor(sc_module_name name, int capacity = 64)
      : sc_module(name),
        mbox(capacity),
        actor_name(::sc_core::sc_module::name()),
        actor_id(next_actor_id()) {
    SC_THREAD(run_loop);
  }

  // Register a typed subscriber for messages of type T. Invoked by the free
  // function wire<T>(producer, consumer); rarely called directly. Keyed by the
  // runtime type name so one dispatch serves both statically-typed publishers
  // and the type-erased transport bridges (which republish a concrete Msg<T>
  // whose type_name() is preserved across the wire). This mirrors the SV core's
  // subscribers_by_type[$typename(...)] keyed routing.
  template <typename T>
  void add_subscriber(Actor* sub) {
    subscribers_by_type[typeid(T).name()].push_back(sub);
  }

  // Type-keyed fan-out publish; non-blocking write to each wired subscriber's
  // mailbox. Routes only to consumers wired for this message's exact type.
  // A backed-up subscriber drops; the producer never stalls.
  void publish(std::shared_ptr<MsgBase> msg) {
    msg->stamp(actor_id);
    auto it = subscribers_by_type.find(msg->type_name());
    if (it == subscribers_by_type.end()) return;
    for (auto* sub : it->second) {
      if (sub->is_alive.load(std::memory_order_relaxed)) {
        sub->mbox.nb_write(msg);
      }
    }
  }

  // Returns true only when ALL wired subscribers accepted (backpressure-aware).
  bool try_publish(std::shared_ptr<MsgBase> msg) {
    msg->stamp(actor_id);
    auto it = subscribers_by_type.find(msg->type_name());
    if (it == subscribers_by_type.end()) return true;
    bool all_ok = true;
    for (auto* sub : it->second) {
      if (sub->is_alive.load(std::memory_order_relaxed)) {
        all_ok = sub->mbox.nb_write(msg) && all_ok;
      }
    }
    return all_ok;
  }

  // Override in subclass; default is a no-op sink.
  virtual void act(std::shared_ptr<MsgBase> /*msg*/) {}

  // Override for cleanup; called by stop().
  virtual void on_terminate() {}

  // Override to reset internal state on supervisor restart.
  // The actor framework's supervision package calls this when a
  // RESTART directive fires; subclasses re-initialize their state
  // here without going through the SC_THREAD lifecycle.
  virtual void reset() {}

  void stop() {
    is_alive.store(false, std::memory_order_relaxed);
    on_terminate();
  }

 private:
  void run_loop() {
    while (is_alive.load(std::memory_order_relaxed)) {
      auto msg = mbox.read();   // blocking; SystemC kernel suspends thread
      if (!is_alive.load()) break;
      act(msg);
    }
  }

  static uint32_t next_actor_id() {
    static std::atomic<uint32_t> counter{1};
    return counter.fetch_add(1, std::memory_order_relaxed);
  }
};

// ---- Declarative wiring primitive ----------------------------------------
// wire<T>(producer, consumer) -- "wire messages of type T from producer to
// consumer". Mirrors the SystemVerilog `WIRE(producer, T, consumer) macro and
// the threads-based C++ tier's wire<T>(). A consumer that wants several types
// from one producer issues one wire<T>() per type; there is no wildcard /
// subscribe-to-everything primitive, so the topology is fully explicit in the
// wiring code and a producer never references its consumers.

template <typename T>
inline void wire(Actor* producer, Actor* consumer) {
  producer->template add_subscriber<T>(consumer);
}

// ---- PUBLISH helper ------------------------------------------------------
// Equivalent of the SV `PUBLISH(payload)` macro: wrap a value in a Msg<T>,
// stamp lineage, fan out to subscribers in one expression.

template <typename T>
inline std::shared_ptr<Msg<T>> make_msg(T payload) {
  return std::make_shared<Msg<T>>(std::move(payload));
}

// PUBLISH_TRACED equivalent: keep ancestry from the message that triggered
// this one.
template <typename T>
inline std::shared_ptr<Msg<T>> make_traced_msg(T payload, const MsgBase& parent) {
  return Msg<T>::from_parent(std::move(payload), parent);
}

}  // namespace actor

#endif  // ACTOR_PKG_SYSTEMC_ACTOR_H
