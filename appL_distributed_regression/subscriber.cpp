// subscriber.cpp -- distributed-regression scoreboard process.
//
// Receives WorkerEvent messages over ZMQ, deserializes them through a
// ZmqSubscriberBridge, and feeds them into a local Scoreboard actor that
// counts events per worker and reports at the end.
//
// The Scoreboard actor knows nothing about ZMQ. It is wired to the bridge
// (via wire<WorkerEvent>()) as if to a local actor; the bridge does the
// network plumbing invisibly. Same architecture as the local-only
// hello_actor example, just with one transport-bridge actor inserted in
// the topology.

#include "actor.h"
#include "zmq_bridge.h"
#include "common.h"
#include <chrono>
#include <iostream>
#include <map>
#include <thread>
using namespace std::chrono_literals;

class Scoreboard : public actor::Actor {
 public:
  using Actor::Actor;

  void act(std::shared_ptr<actor::MsgBase> m) override {
    auto* typed = dynamic_cast<actor::Msg<WorkerEvent>*>(m.get());
    if (typed == nullptr) return;
    const auto& e = typed->payload;
    counts_[e.worker_id]++;
    std::cout << "[scoreboard @ " << sc_time_stamp() << "] "
              << "worker=" << e.worker_id
              << " seq=" << e.seq
              << " result=" << e.result
              << " trace_id=" << m->trace_id
              << "\n";
  }

  void report() {
    std::cout << "[scoreboard] final counts:\n";
    for (auto& kv : counts_) {
      std::cout << "  worker " << kv.first << " : " << kv.second << " events\n";
    }
  }

 private:
  std::map<uint32_t, int> counts_;
};

// Drain SC_THREAD: pulls staged messages from the ZMQ subscriber on each
// SystemC delta cycle and republishes into the local topology.
class DrainActor : public actor::Actor {
 public:
  DrainActor(sc_module_name name, actor::ZmqSubscriberBridge<WorkerEvent>* sub)
      : Actor(name), sub_(sub) {
    SC_THREAD(drain_loop);
  }
 private:
  actor::ZmqSubscriberBridge<WorkerEvent>* sub_;
  void drain_loop() {
    // Run for ~3 seconds wall, draining ZMQ queue every ~50 ms.
    for (int i = 0; i < 60; ++i) {
      sub_->drain();
      std::this_thread::sleep_for(50ms);
      wait(SC_ZERO_TIME);
    }
  }
};

int sc_main(int /*argc*/, char* /*argv*/[]) {
  Scoreboard                                  scb("scoreboard");
  actor::ZmqSubscriberBridge<WorkerEvent>     sub("zmq_sub",
                                                  "tcp://localhost:5555",
                                                  "worker_event");
  DrainActor                                  drain("drain", &sub);

  // Bridge -> Scoreboard: scoreboard receives republished events by type.
  actor::wire<WorkerEvent>(&sub, &scb);

  std::cout << "[subscriber] connected to tcp://localhost:5555 ; running ~3 s wall\n";
  sc_start(1, SC_MS);

  scb.report();
  std::cout << "[subscriber] simulation complete at " << sc_time_stamp() << "\n";
  return 0;
}
