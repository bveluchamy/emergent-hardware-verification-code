// hello_actor.cpp -- minimal SystemC actor example.
//
// Two actors: a producer that publishes a "tick" message every 10 ns, and
// a consumer that prints what it receives. wire<TickEvent>() wires producer
// -> consumer; sc_start runs the SystemC kernel for 100 ns.
//
// Mirrors ch6_actor_examples/01_hello_actor in the SV side. The point is
// that the same actor topology (one source, one sink, one typed wire<T>()
// edge) expresses naturally in either language; the kernel handles
// concurrency in both cases.

#include "actor.h"
#include <iostream>

// Typed payload struct. Plain old data; copied by value through the mailbox.
struct TickEvent {
  int        seq;
  double     time_ns;
};

class TickProducer : public actor::Actor {
 public:
  explicit TickProducer(sc_module_name name) : Actor(name) {
    SC_THREAD(generate);
  }

 private:
  void generate() {
    for (int i = 0; i < 5; ++i) {
      wait(10, SC_NS);
      TickEvent ev{i, sc_time_stamp().to_seconds() * 1e9};
      publish(actor::make_msg(ev));
    }
  }
};

class TickConsumer : public actor::Actor {
 public:
  using Actor::Actor;

  void act(std::shared_ptr<actor::MsgBase> m) override {
    auto* typed = dynamic_cast<actor::Msg<TickEvent>*>(m.get());
    if (typed != nullptr) {
      const auto& ev = typed->payload;
      std::cout << "[" << sc_time_stamp() << "] "
                << "TickConsumer got seq=" << ev.seq
                << " time_ns=" << ev.time_ns
                << " trace_id=" << m->trace_id
                << "\n";
    }
  }
};

int sc_main(int /*argc*/, char* /*argv*/[]) {
  TickProducer prod("producer");
  TickConsumer cons("consumer");

  actor::wire<TickEvent>(&prod, &cons);

  sc_start(100, SC_NS);

  std::cout << "[hello_actor] simulation complete at " << sc_time_stamp() << "\n";
  return 0;
}
