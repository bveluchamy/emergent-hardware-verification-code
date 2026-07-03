// coro_pipeline.cpp -- coroutine actor pipeline (ingester -> parser -> sink).
//
// Three coroutine actors composed via declarative typed wiring. Each actor's
// run() is a forever loop that awaits a message, transforms it, and emits
// downstream via publish<T>(). Topology --- "RawLine flows from ingester to
// parser, ParsedRec from parser to aggregator, SummaryUpdate from aggregator
// to sink" --- is declared with wire<T>() at startup; the actor bodies never
// reference their peers. The framework runs all of this on a small worker
// pool (M:N green threads); thousands of actors in this style fit easily on
// commodity hardware.

#include "coro_actor.h"

#include <atomic>
#include <chrono>
#include <cstring>
#include <iostream>
#include <random>
#include <string>
#include <thread>

using actor::coro::CoroActor;
using actor::coro::Msg;
using actor::coro::MsgBase;
using actor::coro::Scheduler;
using actor::coro::Task;
using actor::coro::wire;

// ---- Plain Old Data message types ---------------------------------------
struct RawLine       { char text[64]; };
struct ParsedRec     { uint32_t level; uint32_t hash; };
struct SummaryUpdate { uint32_t level; uint64_t count; };

// ---- Ingester actor (synthetic source) ----------------------------------
class IngesterActor : public CoroActor {
 public:
  int n_lines = 30;

  Task<void> run() override {
    std::mt19937 rng(7);
    std::uniform_int_distribution<int> level_dist(0, 3);
    static const char* lvls[] = {"DEBUG", "INFO ", "WARN ", "ERROR"};
    for (int i = 0; i < n_lines && alive(); ++i) {
      RawLine line{};
      int lvl = level_dist(rng);
      std::snprintf(line.text, sizeof(line.text), "%s event #%d", lvls[lvl], i);
      publish(line);
    }
    co_return;
  }
};

// ---- Parser actor --------------------------------------------------------
class ParserActor : public CoroActor {
 public:
  std::atomic<uint64_t> parsed{0};

  Task<void> run() override {
    while (alive()) {
      auto msg = co_await mbox_.recv();
      auto line = std::dynamic_pointer_cast<Msg<RawLine>>(msg);
      if (!line) continue;
      ParsedRec rec{};
      const char* t = line->payload.text;
      if      (t[0] == 'D') rec.level = 0;
      else if (t[0] == 'I') rec.level = 1;
      else if (t[0] == 'W') rec.level = 2;
      else                  rec.level = 3;
      uint32_t h = 2166136261u;
      for (size_t i = 2; i < sizeof(line->payload.text) && t[i]; ++i) {
        h = (h ^ static_cast<uint8_t>(t[i])) * 16777619u;
      }
      rec.hash = h;
      parsed.fetch_add(1, std::memory_order_relaxed);
      publish(rec);
    }
    co_return;
  }
};

// ---- Aggregator actor ----------------------------------------------------
class AggregatorActor : public CoroActor {
 public:
  uint64_t level_counts[4]{};

  Task<void> run() override {
    while (alive()) {
      auto msg = co_await mbox_.recv();
      auto r = std::dynamic_pointer_cast<Msg<ParsedRec>>(msg);
      if (!r) continue;
      uint32_t lvl = r->payload.level;
      level_counts[lvl]++;
      if ((level_counts[lvl] % 5) == 0) {
        publish(SummaryUpdate{lvl, level_counts[lvl]});
      }
    }
    co_return;
  }
};

// ---- Sink actor ----------------------------------------------------------
class SinkActor : public CoroActor {
 public:
  std::atomic<uint64_t> updates{0};

  Task<void> run() override {
    static const char* level_names[] = {"DEBUG", "INFO ", "WARN ", "ERROR"};
    while (alive()) {
      auto msg = co_await mbox_.recv();
      auto u = std::dynamic_pointer_cast<Msg<SummaryUpdate>>(msg);
      if (!u) continue;
      updates.fetch_add(1, std::memory_order_relaxed);
      std::cout << "[sink] " << level_names[u->payload.level]
                << " count=" << u->payload.count << "\n";
    }
    co_return;
  }
};

int main() {
  Scheduler::instance().start(3);

  IngesterActor   ingester;
  ParserActor     parser;
  AggregatorActor aggregator;
  SinkActor       sink;

  // Topology: ingester -> parser -> aggregator -> sink. Three typed edges.
  wire<RawLine>      (&ingester,   &parser);
  wire<ParsedRec>    (&parser,     &aggregator);
  wire<SummaryUpdate>(&aggregator, &sink);

  ingester.start();
  parser.start();
  aggregator.start();
  sink.start();

  std::cout << "[coro_pipeline] starting ingestion of 30 lines\n";

  // Wait for ingester to finish and downstream to drain.
  std::this_thread::sleep_for(std::chrono::milliseconds(400));

  std::cout << "[coro_pipeline] parsed=" << parser.parsed.load()
            << " sink_updates=" << sink.updates.load() << "\n";

  ingester.stop();
  parser.stop();
  aggregator.stop();
  sink.stop();
  // Wake actors so they observe the alive flag and co_return.
  parser.publish(RawLine{});
  aggregator.publish(ParsedRec{});
  sink.publish(SummaryUpdate{});

  Scheduler::instance().stop();
  return 0;
}
