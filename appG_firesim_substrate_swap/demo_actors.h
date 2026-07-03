// demo_actors.h -- platform-independent verification actors for the
// substrate-swap demonstration.
//
// THE POINT: these actors are authored ONCE and reused UNCHANGED across
// substrates. Stage 0 (here) drives them against a synthesizable RTL actor
// hosted by Verilator; the FireSim scaffold (./firesim/) drives the SAME
// actors against the SAME synthesizable actor running on an FPGA. Only the
// proxy/bridge that connects to the device-under-test changes -- the stimulus,
// the scoreboard's golden model, the coverage, and the `WIRE topology do not.
//
// Uses the book's own C++ actor framework (actor_pkg_cpp/include/actor.h):
// declarative typed wiring via wire<T>(), type-routed publish<T>().

#ifndef DEMO_ACTORS_H
#define DEMO_ACTORS_H

#include "actor.h"

#include <array>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace demo {

using actor::cpp::Actor;
using actor::cpp::Msg;
using actor::cpp::MsgBase;
using actor::cpp::wire;   // so wire<T>(...) resolves unqualified in C++17

// ---- typed messages carried over `WIRE edges --------------------------------
struct AddReq { uint32_t data; uint64_t txid; };  // accumulate this value
struct AddRsp { uint32_t sum;  uint64_t txid; };  // running sum after it

// Deterministic stimulus stream: a 16-bit Galois LFSR identical to the one in
// stimulus_actor.sv (SEED=0xACE1, TAPS=0xB400). Using the same generator in
// both renderings makes the two substrates agree bit for bit.
inline std::vector<uint32_t> make_data(uint64_t n) {
  std::vector<uint32_t> v;
  v.reserve(n);
  uint16_t s = 0xACE1u;
  for (uint64_t i = 0; i < n; ++i) {
    v.push_back(s);
    s = static_cast<uint16_t>((s >> 1) ^ ((s & 1u) ? 0xB400u : 0u));
  }
  return v;
}

// downcast helper: returns nullptr if the envelope is not Msg<T>
template <typename T>
static inline const T* as(const std::shared_ptr<MsgBase>& m) {
  auto p = std::dynamic_pointer_cast<Msg<T>>(m);
  return p ? &p->payload : nullptr;
}

// ---- Stimulus actor: emits a fixed sequence of AddReq ------------------------
class StimulusActor : public Actor {
 public:
  StimulusActor(std::string n, std::vector<uint32_t> data)
      : Actor(std::move(n)), data_(std::move(data)) {}
  // Publish all requests. Call after the topology is wired and consumers
  // started. publish<AddReq>() fans out only to actors wired for AddReq.
  void fire() {
    for (uint64_t i = 0; i < data_.size(); ++i)
      publish<AddReq>(AddReq{data_[i], i});
  }
  uint64_t count() const { return data_.size(); }
 private:
  std::vector<uint32_t> data_;
};

// ---- Scoreboard actor: golden accumulator + response checker ----------------
// Substrate-agnostic: it never knows whether the responses come from a software
// actor or a synthesizable RTL actor on an FPGA. It matches by txid and is
// robust to req/rsp arrival order (buffers whichever side arrives first).
class ScoreboardActor : public Actor {
 public:
  explicit ScoreboardActor(std::string n) : Actor(std::move(n)) {}

  void act(std::shared_ptr<MsgBase> m) override {
    if (auto* r = as<AddReq>(m)) {        // golden model advances in request order
      golden_ += r->data;
      expected_[r->txid] = golden_;
      match(r->txid);
    } else if (auto* s = as<AddRsp>(m)) { // DUT response
      got_[s->txid] = s->sum;
      match(s->txid);
    }
  }

  void wait_done(uint64_t n) {
    std::unique_lock<std::mutex> lk(mx_);
    cv_.wait(lk, [&] { return processed_ >= n; });
  }
  uint64_t checks() const { return checks_; }
  uint64_t fails()  const { return fails_; }

 private:
  void match(uint64_t txid) {
    auto e = expected_.find(txid);
    auto g = got_.find(txid);
    if (e == expected_.end() || g == got_.end()) return;
    ++checks_;
    if (e->second != g->second) {
      ++fails_;
      std::printf("  [scoreboard] MISMATCH txid=%llu expected=%u got=%u\n",
                  (unsigned long long)txid, e->second, g->second);
    }
    expected_.erase(e);
    got_.erase(g);
    {
      std::lock_guard<std::mutex> lk(mx_);
      ++processed_;
    }
    cv_.notify_all();
  }

  uint32_t golden_ = 0;
  std::unordered_map<uint64_t, uint32_t> expected_, got_;
  uint64_t checks_ = 0, fails_ = 0, processed_ = 0;
  std::mutex mx_;
  std::condition_variable cv_;
};

// ---- Coverage actor: bins the inbound payloads ------------------------------
class CoverageActor : public Actor {
 public:
  explicit CoverageActor(std::string n) : Actor(std::move(n)) { bins_.fill(false); }
  void act(std::shared_ptr<MsgBase> m) override {
    if (auto* r = as<AddReq>(m)) bins_[r->data & 7u] = true;  // 8 low-order buckets
  }
  int covered() const {
    int c = 0;
    for (bool b : bins_) c += b ? 1 : 0;
    return c;
  }
 private:
  std::array<bool, 8> bins_{};
};

// ---- Software rendering of the DUT actor (no RTL) ----------------------------
// The SAME accumulator, expressed as a C++ actor. Demonstrates that the
// verification actors above are substrate-agnostic: the DUT-actor can be this
// software object or the synthesizable RTL block; nothing else changes.
class SoftwareDutActor : public Actor {
 public:
  explicit SoftwareDutActor(std::string n) : Actor(std::move(n)) {}
  void act(std::shared_ptr<MsgBase> m) override {
    if (auto* r = as<AddReq>(m)) {
      sum_ += r->data;
      publish<AddRsp>(AddRsp{sum_, r->txid});
    }
  }
 private:
  uint32_t sum_ = 0;
};

}  // namespace demo

#endif  // DEMO_ACTORS_H
