// coro_pingpong.cpp -- coroutine actor ping-pong.
//
// Two actors bounce a counter back and forth. Topology is declared with
// wire<T>() calls at startup; neither actor references the other in its
// code, exactly like hardware modules connected at the parent level. The
// framework handles the scheduling without any std::thread per actor.

#include "coro_actor.h"

#include <atomic>
#include <chrono>
#include <iostream>
#include <thread>

using actor::coro::CoroActor;
using actor::coro::Msg;
using actor::coro::MsgBase;
using actor::coro::Scheduler;
using actor::coro::Task;
using actor::coro::wire;

struct Ping { uint64_t seq; };
struct Pong { uint64_t seq; };

// PingActor receives Pongs (from whoever is wired to send Pong messages to
// it) and emits Pings. It has no reference to PongActor in its body.
class PingActor : public CoroActor {
 public:
  uint64_t              target = 0;
  std::atomic<uint64_t> total{0};

  Task<void> run() override {
    while (alive()) {
      auto msg = co_await mbox_.recv();
      auto p = std::dynamic_pointer_cast<Msg<Pong>>(msg);
      if (!p) continue;
      uint64_t prev = total.fetch_add(1, std::memory_order_relaxed);
      if (prev + 1 < target) {
        publish(Ping{p->payload.seq + 1});
      }
    }
    co_return;
  }
};

// PongActor receives Pings and emits Pongs. No reference to PingActor.
class PongActor : public CoroActor {
 public:
  Task<void> run() override {
    while (alive()) {
      auto msg = co_await mbox_.recv();
      auto p = std::dynamic_pointer_cast<Msg<Ping>>(msg);
      if (!p) continue;
      publish(Pong{p->payload.seq + 1});
    }
    co_return;
  }
};

int main() {
  Scheduler::instance().start(2);

  PingActor ping;
  PongActor pong;

  // Topology: ping emits Pings -> pong; pong emits Pongs -> ping. The two
  // wire<T>() lines are the complete description of the topology.
  wire<Ping>(&ping, &pong);
  wire<Pong>(&pong, &ping);

  constexpr uint64_t N_ROUNDS = 1'000'000;
  ping.target = N_ROUNDS;

  ping.start();
  pong.start();

  std::cout << "[coro_pingpong] " << N_ROUNDS << " rounds = "
            << (N_ROUNDS * 2) << " messages on "
            << Scheduler::instance().threads() << " threads\n";

  auto t0 = std::chrono::steady_clock::now();
  // Kick off the chain by emitting the first Ping into the network. The
  // wired topology delivers it to pong.
  ping.publish(Ping{0});

  while (ping.total.load(std::memory_order_acquire) < N_ROUNDS) {
    std::this_thread::sleep_for(std::chrono::microseconds(500));
  }

  auto t1 = std::chrono::steady_clock::now();
  auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
  uint64_t total_msgs = N_ROUNDS * 2;

  std::cout << "[coro_pingpong] " << total_msgs << " messages in "
            << (ns / 1'000'000.0) << " ms = "
            << (total_msgs * 1e9 / static_cast<double>(ns))
            << " msg/s (single pair, M:N green threads)\n";

  ping.stop();
  pong.stop();
  // Wake the actors so they can co_return on the alive flag flip.
  ping.publish(Ping{0});
  pong.publish(Pong{0});

  Scheduler::instance().stop();
  return 0;
}
