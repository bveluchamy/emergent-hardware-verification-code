// test_fifo.cpp -- 8-bit synchronous FIFO, depth 4, with full/empty flags.
//
// SV equivalent (abbreviated):
//   module fifo4 #(parameter DEPTH=4, WIDTH=8)
//                (input  logic clk, rst, push, pop,
//                 input  logic [WIDTH-1:0] din,
//                 output logic [WIDTH-1:0] dout,
//                 output logic full, empty);
//     logic [WIDTH-1:0] mem [DEPTH];
//     logic [1:0] rptr, wptr;
//     logic [2:0] count;
//     always_ff @(posedge clk) begin
//       if (rst) begin rptr <= 0; wptr <= 0; count <= 0; end
//       else begin
//         if (push && !full) begin mem[wptr] <= din; wptr <= wptr + 1; end
//         if (pop  && !empty) rptr <= rptr + 1;
//         count <= count + (push && !full) - (pop && !empty);
//       end
//     end
//     assign dout  = mem[rptr];
//     assign empty = (count == 0);
//     assign full  = (count == DEPTH);
//   endmodule
//
// In the actor model this becomes: a FifoActor with internal mem array,
// rptr, wptr, count -- all updated synchronously by the clock-edge
// handler. The actor framework's encapsulation means mem stays private to
// the FifoActor instance, exactly as the SV module's local logic stays
// inside the module. Multiple FIFOs in the same design are multiple
// FifoActor instances with separate state.
//
// This test also exercises VCD output: trace.vcd is emitted and can be
// opened in GTKWave for waveform debugging.

#include "actor_sim.h"
#include "vcd_writer.h"

#include <array>
#include <cstdio>

namespace asim = actor::sim;

class FifoActor : public asim::Module {
public:
    FifoActor(std::string name,
              asim::Signal<8>* din, asim::Signal<1>* push,
              asim::Signal<1>* pop, asim::Signal<8>* dout,
              asim::Signal<1>* full, asim::Signal<1>* empty,
              asim::Signal<3>* count_out)
        : name_(std::move(name)),
          din_(din), push_(push), pop_(pop),
          dout_(dout), full_(full), empty_(empty), count_out_(count_out) {
        update_flags_();
    }

    void on_clock_edge() override {
        bool do_push = (push_->read() != asim::Bit(0)) && !is_full_();
        bool do_pop  = (pop_->read()  != asim::Bit(0)) && !is_empty_();
        if (do_push) {
            mem_[wptr_] = (uint64_t)din_->read();
            wptr_ = (wptr_ + 1) & 0x3;
        }
        if (do_pop) {
            rptr_ = (rptr_ + 1) & 0x3;
        }
        if (do_push && !do_pop)      ++count_;
        else if (do_pop && !do_push) --count_;
        update_flags_();
    }

    void on_reset() override {
        rptr_ = wptr_ = 0;
        count_ = 0;
        mem_.fill(0);
        update_flags_();
    }

    std::string name() const override { return name_; }

private:
    void update_flags_() {
        full_->write(asim::Bit(count_ == 4 ? 1 : 0));
        empty_->write(asim::Bit(count_ == 0 ? 1 : 0));
        count_out_->write(asim::Bits<3>(count_));
        dout_->write(asim::Bits<8>(mem_[rptr_]));
    }
    bool is_full_()  const { return count_ == 4; }
    bool is_empty_() const { return count_ == 0; }

    std::string         name_;
    asim::Signal<8>*    din_;
    asim::Signal<1>*    push_;
    asim::Signal<1>*    pop_;
    asim::Signal<8>*    dout_;
    asim::Signal<1>*    full_;
    asim::Signal<1>*    empty_;
    asim::Signal<3>*    count_out_;
    std::array<uint64_t, 4> mem_{};
    int                 rptr_  = 0;
    int                 wptr_  = 0;
    int                 count_ = 0;
};

int main() {
    using namespace actor::sim;
    Sim sim;
    TestHarness th("fifo4");

    auto* din   = sim.signal<8>("din");
    auto* push  = sim.signal<1>("push");
    auto* pop   = sim.signal<1>("pop");
    auto* dout  = sim.signal<8>("dout");
    auto* full  = sim.signal<1>("full");
    auto* empty = sim.signal<1>("empty");
    auto* count = sim.signal<3>("count");

    sim.add<FifoActor>("dut", din, push, pop, dout, full, empty, count);

    // Open VCD waveform.
    VcdWriter vcd("test_fifo.vcd", "1 ns");
    vcd.register_signal(din,   "din",   "top.dut");
    vcd.register_signal(push,  "push",  "top.dut");
    vcd.register_signal(pop,   "pop",   "top.dut");
    vcd.register_signal(dout,  "dout",  "top.dut");
    vcd.register_signal(full,  "full",  "top.dut");
    vcd.register_signal(empty, "empty", "top.dut");
    vcd.register_signal(count, "count", "top.dut");
    vcd.write_header();

    auto tick_and_dump = [&]() {
        sim.tick();
        vcd.dump(sim.cycle() * 10);
    };

    sim.reset();
    th.expect_eq<1>("empty after reset", Bit(1), empty->read(), 0);
    th.expect_eq<1>("full after reset",  Bit(0), full->read(),  0);
    th.expect_eq<3>("count after reset", Bits<3>(0), count->read(), 0);

    // Push 0xAA
    din->write(Bits<8>(0xAA));
    push->write(Bit(1));
    tick_and_dump();
    push->write(Bit(0));
    th.expect_eq<3>("count after 1 push", Bits<3>(1), count->read(), sim.cycle());
    th.expect_eq<1>("empty after 1 push", Bit(0), empty->read(), sim.cycle());
    th.expect_eq<8>("dout shows head 0xAA", Bits<8>(0xAA), dout->read(), sim.cycle());

    // Push 0xBB, 0xCC, 0xDD -- fill to capacity
    for (uint64_t v : {0xBBu, 0xCCu, 0xDDu}) {
        din->write(Bits<8>(v));
        push->write(Bit(1));
        tick_and_dump();
    }
    push->write(Bit(0));
    th.expect_eq<3>("count when full", Bits<3>(4), count->read(), sim.cycle());
    th.expect_eq<1>("full",            Bit(1), full->read(),  sim.cycle());

    // Push when full: count stays at 4.
    din->write(Bits<8>(0xEE));
    push->write(Bit(1));
    tick_and_dump();
    push->write(Bit(0));
    th.expect_eq<3>("count after push-when-full", Bits<3>(4), count->read(), sim.cycle());

    // Pop -- should yield 0xAA (FIFO order)
    pop->write(Bit(1));
    tick_and_dump();
    pop->write(Bit(0));
    th.expect_eq<3>("count after 1 pop", Bits<3>(3), count->read(), sim.cycle());
    th.expect_eq<1>("not full after pop", Bit(0), full->read(), sim.cycle());
    th.expect_eq<8>("dout = next head 0xBB", Bits<8>(0xBB), dout->read(), sim.cycle());

    // Pop remaining three: 0xBB, 0xCC, 0xDD
    pop->write(Bit(1));
    tick_and_dump();
    th.expect_eq<8>("dout = 0xCC",  Bits<8>(0xCC), dout->read(), sim.cycle());
    tick_and_dump();
    th.expect_eq<8>("dout = 0xDD",  Bits<8>(0xDD), dout->read(), sim.cycle());
    tick_and_dump();
    pop->write(Bit(0));
    th.expect_eq<3>("count empty after drain", Bits<3>(0), count->read(), sim.cycle());
    th.expect_eq<1>("empty",                   Bit(1), empty->read(), sim.cycle());

    // Pop when empty: stays empty.
    pop->write(Bit(1));
    tick_and_dump();
    pop->write(Bit(0));
    th.expect_eq<1>("still empty after pop-when-empty", Bit(1), empty->read(), sim.cycle());
    th.expect_eq<3>("count still 0",                    Bits<3>(0), count->read(), sim.cycle());

    // Concurrent push + pop: count unchanged.
    din->write(Bits<8>(0x11));
    push->write(Bit(1));
    tick_and_dump();
    push->write(Bit(0));
    th.expect_eq<3>("count after push", Bits<3>(1), count->read(), sim.cycle());
    push->write(Bit(1));
    pop->write(Bit(1));
    din->write(Bits<8>(0x22));
    tick_and_dump();
    push->write(Bit(0));
    pop->write(Bit(0));
    th.expect_eq<3>("count unchanged on simultaneous push+pop",
                   Bits<3>(1), count->read(), sim.cycle());

    vcd.close();
    std::cout << "  VCD waveform written to test_fifo.vcd\n";
    return th.summary();
}
