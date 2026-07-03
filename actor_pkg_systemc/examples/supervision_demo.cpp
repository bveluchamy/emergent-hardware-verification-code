// supervision_demo.cpp -- Erlang/OTP supervision in the SystemC actor port.
//
// A FlakyActor counts inbound ticks; every 3 ticks it "fails" by
// publishing a ChildFailureMsg up to its supervisor. The supervisor
// applies its strategy (ONE_FOR_ONE here) and resets the actor's
// state. The demo also wires a DeathWatcher: a separate Watcher actor
// receives notifications when a third actor (UnrelatedActor) is
// stopped.
//
// Output should show: 6 failures, 6 restarts, count resetting each
// time, then a final "stopped" + DeathMsg notification.

#include "actor.h"
#include "supervision.h"
#include <iostream>

using actor::supervision::ChildFailureMsg;
using actor::supervision::DeathMsg;
using actor::supervision::DeathWatcher;
using actor::supervision::Supervisor;

struct Tick {};

class FlakyActor : public actor::Actor {
 public:
  FlakyActor(sc_module_name name) : Actor(name) {}

  void act(std::shared_ptr<actor::MsgBase> m) override {
    if (dynamic_cast<actor::Msg<Tick>*>(m.get()) == nullptr) return;

    count_++;
    std::cout << "[" << sc_time_stamp() << "] " << actor_name
              << " tick: count=" << count_ << "\n";

    if (count_ >= 3) {
      ChildFailureMsg f{
        actor_id, actor_name, "tick budget exceeded",
        static_cast<uint64_t>(sc_time_stamp().to_seconds() * 1e9)};
      std::cout << "[" << sc_time_stamp() << "] " << actor_name
                << " FAILING (publishing ChildFailureMsg up)\n";
      publish(actor::make_msg(f));
    }
  }

  // Supervisor will call this on RESTART.
  void reset() override {
    std::cout << "[" << sc_time_stamp() << "] " << actor_name
              << " reset(): count " << count_ << " -> 0\n";
    count_ = 0;
  }

 private:
  int count_ = 0;
};

class TickGenerator : public actor::Actor {
 public:
  TickGenerator(sc_module_name name, int n_ticks)
      : Actor(name), n_ticks_(n_ticks) {
    SC_THREAD(generate);
  }

 private:
  int n_ticks_;
  void generate() {
    for (int i = 0; i < n_ticks_; ++i) {
      wait(10, SC_NS);
      publish(actor::make_msg(Tick{}));
    }
  }
};

class WatcherActor : public actor::Actor {
 public:
  WatcherActor(sc_module_name name) : Actor(name) {}

  void act(std::shared_ptr<actor::MsgBase> m) override {
    auto* d = dynamic_cast<actor::Msg<DeathMsg>*>(m.get());
    if (d == nullptr) return;
    std::cout << "[" << sc_time_stamp() << "] " << actor_name
              << " saw death of '" << d->payload.actor_name
              << "' (id=" << d->payload.actor_id << ")\n";
  }
};

class UnrelatedActor : public actor::Actor {
 public:
  using Actor::Actor;
};

int sc_main(int /*argc*/, char* /*argv*/[]) {
  TickGenerator    gen("ticker", 18);                  // 18 ticks -> 6 fails
  FlakyActor       flaky("flaky");
  Supervisor       sup("supervisor");
  WatcherActor     watcher("watcher");
  UnrelatedActor   monitored("monitored");
  DeathWatcher     dw;

  // Topology:
  //   ticker --wire<Tick>()-->            flaky
  //   flaky  --wire<ChildFailureMsg>()--> sup     (failures bubble up)
  //   sup's reset() restores flaky's state
  actor::wire<Tick>(&gen, &flaky);
  actor::wire<ChildFailureMsg>(&flaky, &sup);

  // Death-watch wiring: watcher monitors `monitored`. When monitored is
  // stopped, the DeathWatcher dispatches a DeathMsg into watcher's mbox.
  sup.supervise(&flaky);
  dw.monitor(&watcher, &monitored);

  std::cout << "[supervision_demo] starting\n";

  // Stop `monitored` after 70 ns to demonstrate DeathWatcher.
  sc_spawn([&]() {
    wait(70, SC_NS);
    monitored.stop();
    dw.notify_death(monitored.actor_id, monitored.actor_name);
  });

  sc_start(300, SC_NS);

  std::cout << "[supervision_demo] simulation complete at " << sc_time_stamp() << "\n";
  return 0;
}
