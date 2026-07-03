// actor_sim.h -- Actor-based hardware simulator prototype.
//
// Models RTL as an actor topology: each hardware module is an actor; each
// wire is a typed signal-mailbox between modules; the clock is a broadcast
// message; flip-flops are two-phase state updaters that capture D and
// publish Q exactly as SystemVerilog's NBA region would.
//
// This is the prototype demonstrating that the actor model can replace
// event-driven simulators (Verilator/VCS) for the synthesizable subset.
// Future work: SV-to-actor compiler, multi-threaded scheduling, FPGA/GPU
// backends. Here: prove the model captures real RTL semantics on a small
// set of canonical designs.
//
// Implementation choices for prototype clarity:
//
//   1. Single-threaded scheduler. Each tick() advances one clock cycle
//      deterministically. The actor framework's per-actor threading is
//      bypassed for testability; the PATH to multi-threading is clear
//      (one std::thread per Module's input mailbox) but the prototype's
//      claim is about model expressiveness, not raw throughput.
//
//   2. Two-phase update. Clock edge captures D into a holding register
//      (DFF::on_clock_edge), then propagates Q to readers via
//      signal->write() / Sim::propagate_(). This reproduces SV's NBA
//      semantics without a centralized event queue: every flip-flop sees
//      the consistent pre-edge state, every reader of Q sees the new
//      post-edge state. Exactly the NBA invariant.
//
//   3. Combinational propagation runs to fixed point. After a signal
//      change, the framework notifies subscribing modules; they may write
//      to other signals; those changes notify further subscribers. A
//      settle counter (MAX_PROPAGATION_ITERS) detects oscillating
//      combinational loops (which would be design bugs in real RTL).
//
//   4. Bits<W> is a template wrapping uint64_t (W up to 64). Wider vectors
//      would lift to a multi-word representation; not needed for prototype
//      designs.
//
// The point of these choices is to make the model EXPLICIT. Verilator and
// VCS pack the same semantics into a centralized event queue with implicit
// scheduling regions; here the model is the data structure.

#ifndef ACTOR_PKG_CPP_SIM_ACTOR_SIM_H
#define ACTOR_PKG_CPP_SIM_ACTOR_SIM_H

#include <array>
#include <cstdint>
#include <functional>
#include <iomanip>
#include <initializer_list>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace actor {
namespace sim {

// ---- Bitvector type (1..1024 bits) --------------------------------------
//
// Internally a std::array of uint64_t words; the high word is masked to W%64
// significant bits. For W<=64 the array collapses to one element and the
// compiler eliminates the loop overhead, matching the single-word fast path
// of typical narrow-bit operations.

template <int W>
struct Bits {
    static_assert(W >= 1 && W <= 1024, "Bits<W>: W must be 1..1024");
    static constexpr int WORDS = (W + 63) / 64;
    static constexpr int BITS_IN_TOP = W % 64 == 0 ? 64 : W % 64;
    using word_t = uint64_t;

    std::array<word_t, WORDS> words{};

    constexpr Bits() = default;

    // Narrow constructor: zero-extends a uint64 into the low word, masks top.
    constexpr Bits(word_t v) {
        words[0] = v;
        mask_top();
    }

    // Wide constructor: little-endian word list. words[0] = low 64 bits.
    Bits(std::initializer_list<word_t> ws) {
        size_t i = 0;
        for (auto w : ws) {
            if (i < WORDS) words[i] = w;
            ++i;
        }
        mask_top();
    }

    static constexpr word_t top_mask() {
        return BITS_IN_TOP == 64 ? ~word_t(0)
                                 : (word_t(1) << BITS_IN_TOP) - 1;
    }

    void mask_top() { words[WORDS - 1] &= top_mask(); }

    Bits& operator=(word_t v) {
        words.fill(0);
        words[0] = v;
        mask_top();
        return *this;
    }

    // Implicit conversion to word_t -- legal only for W<=64; emits the low
    // word for wider types (the user must explicitly slice if more is wanted).
    operator word_t() const { return words[0]; }

    bool operator==(const Bits& o) const { return words == o.words; }
    bool operator!=(const Bits& o) const { return words != o.words; }

    // Bitwise ops.
    Bits operator&(const Bits& o) const {
        Bits r;
        for (int i = 0; i < WORDS; ++i) r.words[i] = words[i] & o.words[i];
        return r;
    }
    Bits operator|(const Bits& o) const {
        Bits r;
        for (int i = 0; i < WORDS; ++i) r.words[i] = words[i] | o.words[i];
        return r;
    }
    Bits operator^(const Bits& o) const {
        Bits r;
        for (int i = 0; i < WORDS; ++i) r.words[i] = words[i] ^ o.words[i];
        r.mask_top();
        return r;
    }
    Bits operator~() const {
        Bits r;
        for (int i = 0; i < WORDS; ++i) r.words[i] = ~words[i];
        r.mask_top();
        return r;
    }

    // Modular add/sub with W-bit truncation. Carry propagates word-to-word.
    Bits operator+(const Bits& o) const {
        Bits r;
        word_t carry = 0;
        for (int i = 0; i < WORDS; ++i) {
            word_t a = words[i];
            word_t b = o.words[i];
            word_t s = a + b;
            word_t c1 = (s < a) ? 1 : 0;
            word_t s2 = s + carry;
            word_t c2 = (s2 < s) ? 1 : 0;
            r.words[i] = s2;
            carry = c1 | c2;
        }
        r.mask_top();
        return r;
    }
    Bits operator-(const Bits& o) const {
        Bits r;
        word_t borrow = 0;
        for (int i = 0; i < WORDS; ++i) {
            word_t a = words[i];
            word_t b = o.words[i];
            word_t d = a - b;
            word_t br1 = (a < b) ? 1 : 0;
            word_t d2 = d - borrow;
            word_t br2 = (d < borrow) ? 1 : 0;
            r.words[i] = d2;
            borrow = br1 | br2;
        }
        r.mask_top();
        return r;
    }

    // Indexed bit access.
    bool bit(int i) const {
        if (i < 0 || i >= W) return false;
        return (words[i >> 6] >> (i & 63)) & 1;
    }
    void set_bit(int i, bool v) {
        if (i < 0 || i >= W) return;
        word_t mask = word_t(1) << (i & 63);
        if (v) words[i >> 6] |= mask;
        else   words[i >> 6] &= ~mask;
    }

    // Hex string, big-endian (high bits first), zero-padded to W bits.
    std::string to_hex() const {
        std::ostringstream os;
        os << std::hex << std::setfill('0');
        // High word: only as many nibbles as needed.
        int top_nibbles = (BITS_IN_TOP + 3) / 4;
        os << std::setw(top_nibbles) << words[WORDS - 1];
        for (int i = WORDS - 2; i >= 0; --i) {
            os << std::setw(16) << words[i];
        }
        return os.str();
    }

    // Binary string, big-endian, for VCD.
    std::string to_binary() const {
        std::string s;
        s.reserve(W);
        for (int i = W - 1; i >= 0; --i) {
            s.push_back(bit(i) ? '1' : '0');
        }
        return s;
    }
};

using Bit = Bits<1>;

// ---- Forward decls -------------------------------------------------------

class Module;

// ---- Signal: typed channel between modules ------------------------------
//
// Each Signal has at most one driver (the hardware single-driver rule) and
// any number of readers. Writers call write(); readers call read(). A
// dirty-bit tracks pending changes; the Sim scheduler commits them between
// scheduling phases.

// Forward decl: Signal stores back-pointer to its Sim so write() can
// enqueue itself in a dirty queue. This converts propagation from O(N
// signals) scan-every-cycle into O(K dirty signals) per cycle.
class Sim;

class SignalBase {
public:
    virtual ~SignalBase() = default;
    virtual void commit() = 0;
    virtual void enqueue_readers(class Sim& sim) = 0;
    virtual bool dirty() const = 0;
    virtual std::string describe_value() const = 0;
    virtual const std::string& name() const = 0;
    virtual void connect_reader(Module* m) = 0;
};

template <int W>
class Signal : public SignalBase {
public:
    Signal(std::string n, Sim* sim) : name_(std::move(n)), sim_(sim) {}

    Bits<W> read() const { return current_; }

    inline void write(Bits<W> v);  // defined after Sim

    void force(Bits<W> v) {
        // For testbench stimulus -- immediate, bypasses propagation.
        current_ = v;
    }

    void commit() override {
        if (!has_pending_) return;
        current_ = next_pending_;
        has_pending_ = false;
    }

    inline void enqueue_readers(Sim& sim) override;

    bool dirty() const override { return has_pending_; }
    std::string describe_value() const override {
        std::ostringstream os;
        os << "0x" << std::hex << (uint64_t)current_;
        return os.str();
    }
    const std::string& name() const override { return name_; }

    void connect_reader(Module* m) override { readers_.push_back(m); }

private:
    std::string name_;
    Sim*        sim_;
    Bits<W>     current_{0};
    Bits<W>     next_pending_{0};
    bool        has_pending_ = false;
    std::vector<Module*> readers_;
};

// ---- Module: a hardware actor -------------------------------------------

class Module {
public:
    virtual ~Module() = default;
    virtual std::string name() const = 0;

    // Combinational reaction: an input signal changed. Default: noop
    // (pure sequential modules ignore).
    virtual void on_input_change() {}

    // Sequential reaction: clock-edge broadcast.
    virtual void on_clock_edge() {}

    // Reset signal asserted.
    virtual void on_reset() {}

    // Bookkeeping for Sim's coalesced-notify queue. Public to avoid friend
    // boilerplate; treat as Sim's private state.
    bool _sim_in_notify_queue = false;
};

// ---- D flip-flop with synchronous reset ---------------------------------

template <int W>
class DFF : public Module {
public:
    DFF(std::string name, Signal<W>* d, Signal<W>* q,
        Bits<W> reset_value = Bits<W>(0))
        : name_(std::move(name)),
          d_(d), q_(q),
          reset_value_(reset_value),
          state_(reset_value) {
        // Initialize output to reset value.
        q_->force(reset_value_);
    }

    void on_clock_edge() override {
        // SV semantics: NBA. Capture D pre-edge, publish Q post-edge.
        // In the actor model: the message arrives, we read D's current
        // value, we write to Q. Q's notify-readers happens at the
        // scheduler's next commit, ensuring all flops see consistent state
        // before any reader sees a new Q.
        state_ = d_->read();
        q_->write(state_);
    }

    void on_reset() override {
        state_ = reset_value_;
        q_->write(state_);
    }

    Bits<W> state() const { return state_; }
    std::string name() const override { return name_; }

private:
    std::string name_;
    Signal<W>* d_;
    Signal<W>* q_;
    Bits<W> reset_value_;
    Bits<W> state_;
};

// ---- Combinational module: a lambda that runs on input changes ----------

class CombLogic : public Module {
public:
    CombLogic(std::string name, std::function<void()> fn)
        : name_(std::move(name)), fn_(std::move(fn)) {}

    void on_input_change() override { fn_(); }
    void on_reset() override { fn_(); }  // Recompute on reset.

    std::string name() const override { return name_; }

    // Register inputs that should notify this module.
    template <typename SigT>
    CombLogic* sensitive_to(SigT* sig) {
        sig->connect_reader(this);
        return this;
    }

private:
    std::string name_;
    std::function<void()> fn_;
};

// ---- Simulator (scheduler) ----------------------------------------------

class Sim {
public:
    Sim() = default;

    // Create a typed signal. Returned pointer is owned by the Sim.
    template <int W>
    Signal<W>* signal(std::string name) {
        auto s = std::make_unique<Signal<W>>(std::move(name), this);
        Signal<W>* p = s.get();
        signals_.push_back(std::move(s));
        return p;
    }

    // Sim-internal: signal enqueues itself in the dirty queue when its
    // write() flips has_pending_ from false to true.
    void _enqueue_dirty(SignalBase* s) { dirty_signals_.push_back(s); }

    // Sim-internal: Signal::enqueue_readers() pushes each subscriber once
    // by checking _sim_in_notify_queue.
    void _enqueue_notify(Module* m) {
        if (!m->_sim_in_notify_queue) {
            m->_sim_in_notify_queue = true;
            notify_queue_.push_back(m);
        }
    }

    // Add an arbitrary module subclass. Returned pointer is owned by Sim.
    template <typename T, typename... Args>
    T* add(Args&&... args) {
        auto m = std::make_unique<T>(std::forward<Args>(args)...);
        T* p = m.get();
        modules_.push_back(std::move(m));
        return p;
    }

    // Helper: add a combinational block with a lambda and sensitivity list.
    template <typename F>
    CombLogic* comb(std::string name, F fn,
                   std::vector<SignalBase*> sensitivity) {
        auto* m = add<CombLogic>(std::move(name), std::function<void()>(fn));
        for (auto* s : sensitivity) {
            s->connect_reader(m);
        }
        fn();          // Initial evaluation.
        propagate_();
        return m;
    }

    // Assert reset for one cycle.
    void reset() {
        for (auto& m : modules_) m->on_reset();
        propagate_();
    }

    // Advance one clock cycle.
    void tick() {
        // Phase 0: settle external stimulus written via signal->write().
        // SV's testbench world: assignments to inputs from the testbench
        // settle through combinational logic before the next clock edge.
        propagate_();
        // Phase 1: clock-edge broadcast to all sequential modules.
        // Each flop reads its D input (current, pre-edge), writes to Q.
        // Other flops in the same loop still see pre-edge Q values --
        // exactly SV's NBA semantic.
        for (auto& m : modules_) {
            m->on_clock_edge();
        }
        // Phase 2: propagate new Q values through combinational logic.
        propagate_();
        ++cycle_;
    }

    void run(int cycles) {
        for (int i = 0; i < cycles; ++i) tick();
    }

    uint64_t cycle() const { return cycle_; }
    size_t module_count() const { return modules_.size(); }
    size_t signal_count() const { return signals_.size(); }

    // Trace helper for debugging: print all signal values.
    void dump_signals(std::ostream& os = std::cout) const {
        os << "[cycle " << cycle_ << "] ";
        for (auto& s : signals_) {
            os << s->name() << "=" << s->describe_value() << " ";
        }
        os << "\n";
    }

private:
    // Run combinational propagation until quiescent.
    //
    // Two queues drive this. dirty_signals_ holds the signals whose
    // next_pending_ differs from current_; commit() promotes them and
    // enqueue_readers() pushes each subscribed module into
    // notify_queue_ once (deduped via Module::_sim_in_notify_queue).
    // Then notify_queue_ drains: each module's on_input_change() runs
    // exactly once, regardless of how many of its inputs changed
    // simultaneously. This is the optimisation that makes a 64-input
    // reducer fire once per cycle instead of 64 times.
    void propagate_() {
        for (int iter = 0; iter < MAX_PROPAGATION_ITERS; ++iter) {
            if (dirty_signals_.empty()) return;
            // Phase A: commit all currently-pending writes, collect their
            // readers into notify_queue_ (deduped).
            for (auto* s : dirty_signals_) {
                s->commit();
                s->enqueue_readers(*this);
            }
            dirty_signals_.clear();
            // Phase B: fire each affected reader exactly once. New writes
            // during these calls go back onto dirty_signals_ for next iter.
            for (auto* m : notify_queue_) {
                m->_sim_in_notify_queue = false;
                m->on_input_change();
            }
            notify_queue_.clear();
        }
        throw std::runtime_error(
            "actor_sim: combinational logic did not converge after " +
            std::to_string(MAX_PROPAGATION_ITERS) +
            " iterations -- combinational loop?");
    }

    static constexpr int MAX_PROPAGATION_ITERS = 200;

    std::vector<std::unique_ptr<Module>>     modules_;
    std::vector<std::unique_ptr<SignalBase>> signals_;
    std::vector<SignalBase*>                 dirty_signals_;
    std::vector<Module*>                     notify_queue_;
    uint64_t                                 cycle_ = 0;
};

// ---- Signal definitions that need Sim type ------------------------------

template <int W>
inline void Signal<W>::write(Bits<W> v) {
    if (v != current_ && v != next_pending_) {
        next_pending_ = v;
        if (!has_pending_) {
            has_pending_ = true;
            sim_->_enqueue_dirty(this);
        }
    } else if (v == current_ && has_pending_) {
        // Driver retracted change before propagation.
        next_pending_ = current_;
        has_pending_ = false;
        // We leave the entry in dirty_signals_; commit() is idempotent on
        // a clean signal (early-returns when has_pending_ is false).
    }
}

template <int W>
inline void Signal<W>::enqueue_readers(Sim& sim) {
    for (auto* m : readers_) sim._enqueue_notify(m);
}

// ---- Simple test harness -------------------------------------------------

class TestHarness {
public:
    explicit TestHarness(std::string name) : name_(std::move(name)) {}

    template <int W>
    void expect_eq(const std::string& signal_name, Bits<W> expected,
                  Bits<W> actual, uint64_t cycle) {
        ++total_;
        if (expected != actual) {
            ++failed_;
            std::cerr << "  [FAIL] cycle=" << cycle << " " << signal_name
                      << " expected=0x" << std::hex << (uint64_t)expected
                      << " actual=0x" << (uint64_t)actual << std::dec << "\n";
        }
    }

    void expect(bool cond, const std::string& msg, uint64_t cycle) {
        ++total_;
        if (!cond) {
            ++failed_;
            std::cerr << "  [FAIL] cycle=" << cycle << " " << msg << "\n";
        }
    }

    int summary() {
        std::cout << "[" << name_ << "] "
                  << (total_ - failed_) << "/" << total_ << " checks passed";
        if (failed_ == 0) std::cout << "  PASS\n";
        else               std::cout << "  *** " << failed_ << " FAILED ***\n";
        return failed_;
    }

private:
    std::string name_;
    int total_ = 0;
    int failed_ = 0;
};

}}  // namespace actor::sim

#endif  // ACTOR_PKG_CPP_SIM_ACTOR_SIM_H
