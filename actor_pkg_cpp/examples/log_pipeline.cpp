// log_pipeline.cpp -- a four-stage log-processing pipeline as actors.
//
// Demonstrates the pure-C++ actor framework on a deliberately non-hardware
// problem: ingest -> parse -> aggregate -> sink. Each stage is one actor;
// declarative wire<T>() calls wire them in series, one typed edge per
// message type. The framework gives you:
//
//   - No shared state between stages (each owns its own data)
//   - Backpressure via try_publish() return values
//   - Lineage stamping (trace_id propagates through the pipeline)
//   - Bounded mailboxes (memory-safe under load)
//
// Compared to a thread-pool + channels design, the actor topology makes
// the dataflow visible at construction time -- you can read the wire<T>()
// calls and see the entire system shape, one typed edge at a time.
//
// Compared to async/await, no callbacks, no future chains, no nested
// continuations. Each actor is a self-contained unit with one input
// and a list of output subscribers.
//
// Compared to CAF, there are no behavior macros, no typed_actor templates,
// no actor system runtime to manage. One #include, one compile, runs.

#include "actor.h"
#include <atomic>
#include <chrono>
#include <cstring>
#include <iostream>
#include <map>
#include <random>
#include <set>
#include <string>
#include <thread>

using actor::cpp::Actor;
using actor::cpp::Msg;
using actor::cpp::MsgBase;
using actor::cpp::make_msg;
using actor::cpp::make_traced_msg;
using actor::cpp::wire;

// ---- Message types: POD structs (DOD-friendly) --------------------------

struct RawLogLine {
  uint64_t  arrival_ns;
  char      text[128];      // fixed-size for cache-line locality
};

struct ParsedRecord {
  uint64_t  arrival_ns;
  uint32_t  level;          // 0=DEBUG 1=INFO 2=WARN 3=ERROR
  uint32_t  source_id;      // hashed component name
  uint32_t  msg_hash;       // hashed message body
};

struct AggregateUpdate {
  uint32_t  level;
  uint32_t  count;
  uint32_t  unique_msgs;
};

// ---- Stage 1: Ingester (synthetic log generator) ------------------------

class Ingester : public Actor {
 public:
  Ingester(const std::string& name, int n_lines)
      : Actor(name), n_lines_(n_lines) {}

  void run_for_demo() {
    std::mt19937 rng(42);
    std::uniform_int_distribution<int> level_dist(0, 3);
    std::uniform_int_distribution<int> sleep_dist(0, 3);
    static const char* levels[] = {"DEBUG", "INFO ", "WARN ", "ERROR"};
    static const char* sources[] = {"net   ", "auth  ", "db    ", "cache "};

    for (int i = 0; i < n_lines_; ++i) {
      RawLogLine line{};
      line.arrival_ns =
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              std::chrono::steady_clock::now().time_since_epoch()).count();
      int lvl = level_dist(rng);
      int src = i % 4;
      std::snprintf(line.text, sizeof(line.text),
                    "%s [%s] event #%d", levels[lvl], sources[src], i);
      publish(line);
      std::this_thread::sleep_for(std::chrono::milliseconds(sleep_dist(rng)));
    }
  }

 private:
  int n_lines_;
};

// ---- Stage 2: Parser (string -> structured record) ----------------------

class Parser : public Actor {
 public:
  using Actor::Actor;

  void act(std::shared_ptr<MsgBase> m) override {
    auto* line = dynamic_cast<Msg<RawLogLine>*>(m.get());
    if (line == nullptr) return;
    ParsedRecord rec{};
    rec.arrival_ns = line->payload.arrival_ns;
    // Parse first 5 chars as level tag, hash everything else.
    rec.level = parse_level(line->payload.text);
    rec.source_id = hash_range(line->payload.text + 7, 6);     // "[xxxxx]"
    rec.msg_hash  = hash_range(line->payload.text + 14,
                                strnlen(line->payload.text, sizeof(line->payload.text)) - 14);
    parsed_count_++;
    // Lineage: the parsed record carries the same trace_id as the raw line.
    publish_msg(make_traced_msg(rec, *m));
  }

  uint64_t parsed_count() const { return parsed_count_; }

 private:
  uint64_t parsed_count_ = 0;

  static uint32_t parse_level(const char* s) {
    if (s[0] == 'D') return 0;
    if (s[0] == 'I') return 1;
    if (s[0] == 'W') return 2;
    return 3;
  }
  static uint32_t hash_range(const char* s, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; ++i) h = (h ^ static_cast<uint8_t>(s[i])) * 16777619u;
    return h;
  }
};

// ---- Stage 3: Aggregator (counts per level + unique messages) -----------

class Aggregator : public Actor {
 public:
  using Actor::Actor;

  void act(std::shared_ptr<MsgBase> m) override {
    auto* rec = dynamic_cast<Msg<ParsedRecord>*>(m.get());
    if (rec == nullptr) return;
    counts_[rec->payload.level]++;
    unique_msgs_[rec->payload.level].insert(rec->payload.msg_hash);

    // Periodically publish an update downstream.
    if ((++since_emit_) % 5 == 0) {
      AggregateUpdate u{};
      u.level       = rec->payload.level;
      u.count       = static_cast<uint32_t>(counts_[rec->payload.level]);
      u.unique_msgs = static_cast<uint32_t>(unique_msgs_[rec->payload.level].size());
      publish_msg(make_traced_msg(u, *m));
    }
  }

  void report() {
    static const char* level_names[] = {"DEBUG", "INFO ", "WARN ", "ERROR"};
    std::cout << "[aggregator] final counts:\n";
    for (auto& kv : counts_) {
      std::cout << "  " << level_names[kv.first] << " : "
                << kv.second << " events ("
                << unique_msgs_[kv.first].size() << " unique)\n";
    }
  }

 private:
  std::map<uint32_t, uint64_t>          counts_;
  std::map<uint32_t, std::set<uint32_t>> unique_msgs_;
  uint64_t                              since_emit_ = 0;
};

// ---- Stage 4: Sink (writes summaries to stdout) -------------------------

class Sink : public Actor {
 public:
  using Actor::Actor;

  void act(std::shared_ptr<MsgBase> m) override {
    auto* u = dynamic_cast<Msg<AggregateUpdate>*>(m.get());
    if (u == nullptr) return;
    static const char* level_names[] = {"DEBUG", "INFO ", "WARN ", "ERROR"};
    std::cout << "[sink trace=" << m->trace_id << "] "
              << level_names[u->payload.level] << " count=" << u->payload.count
              << " unique=" << u->payload.unique_msgs << "\n";
  }
};

int main() {
  Ingester    ingester("ingester", 30);
  Parser      parser("parser");
  Aggregator  aggregator("aggregator");
  Sink        sink("sink");

  // Topology: ingest -> parse -> aggregate -> sink. Each edge is one
  // typed wire; reading the wire<T>() calls is reading the dataflow.
  wire<RawLogLine>     (&ingester,   &parser);
  wire<ParsedRecord>   (&parser,     &aggregator);
  wire<AggregateUpdate>(&aggregator, &sink);

  // Spawn dispatch threads. Order doesn't matter because mailboxes are
  // already in place.
  parser.start();
  aggregator.start();
  sink.start();

  std::cout << "[log_pipeline] starting ingestion of 30 lines\n";
  ingester.run_for_demo();

  // Drain: wait for downstream actors to consume the in-flight messages.
  std::this_thread::sleep_for(std::chrono::milliseconds(200));

  // Stop the actors cleanly.
  sink.stop();
  aggregator.stop();
  parser.stop();

  std::cout << "[log_pipeline] parsed " << parser.parsed_count()
            << " records\n";
  aggregator.report();
  return 0;
}
