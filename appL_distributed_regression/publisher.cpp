// publisher.cpp -- distributed-regression worker process.
//
// Runs a couple of source actors that publish WorkerEvent messages and a
// ZmqPublisherBridge that forwards them out over ZMQ. A subscriber
// process (subscriber.cpp) and a Python observer (subscriber.py) attach
// to the same endpoint and observe the same events.
//
// The point of this demo: the actor topology is identical to the local
// in-process case. The bridges turn a single-process pub/sub into a
// multi-process / multi-machine / polyglot pub/sub without touching the
// publisher actors or the consumer scoreboards.

#include "actor.h"
#include "zmq_bridge.h"
#include "common.h"
#include <chrono>
#include <iostream>
#include <thread>

class WorkerActor : public actor::Actor {
 public:
  WorkerActor(sc_module_name name, uint32_t id, int n_events)
      : Actor(name), id_(id), n_events_(n_events) {
    SC_THREAD(work_loop);
  }

 private:
  uint32_t id_;
  int      n_events_;

  void work_loop() {
    // Wait wall-time so any out-of-process subscribers have time to
    // connect (ZMQ slow-joiner). For an in-process simulation this would
    // not be needed; the framework topology is the same either way.
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    for (int i = 0; i < n_events_; ++i) {
      wait(50, SC_NS);
      WorkerEvent e{
          id_,
          static_cast<uint32_t>(i),
          static_cast<uint64_t>(sc_time_stamp().to_seconds() * 1e9),
          id_ * 1000u + static_cast<uint32_t>(i)};
      publish(actor::make_msg(e));
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  }
};

int sc_main(int /*argc*/, char* /*argv*/[]) {
  WorkerActor                       worker_a("worker_a", 1, 5);
  WorkerActor                       worker_b("worker_b", 2, 5);
  actor::ZmqPublisherBridge<WorkerEvent> bridge("zmq_pub",
                                                "tcp://*:5555",
                                                "worker_event");

  actor::wire<WorkerEvent>(&worker_a, &bridge);
  actor::wire<WorkerEvent>(&worker_b, &bridge);

  std::cout << "[publisher] starting; ZMQ pub on tcp://*:5555\n";
  sc_start(1, SC_US);
  std::cout << "[publisher] simulation complete at " << sc_time_stamp() << "\n";
  return 0;
}
