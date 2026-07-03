// 06_verification_demo — full DOD verification stack on a tiny memory model.
// Demonstrates:
//   * ConstraintActor   — random stimulus, hot-swappable
//   * MemoryDut         — actor that mimics a memory DUT (returns Rsp on Req)
//   * SpecActor         — golden-model actor consuming the same input
//   * DiffActor         — compares DUT vs Spec responses by trace_id
//   * CoverageActor     — bin sampling on the request stream
//     (ScoreboardActor, the fifth verification base, is demonstrated in
//      09_integration)
//
// All four live as independent subscribers — zero coupling to MemoryDut.

`timescale 1ns/1ns

package vdemo_pkg;
  import actor_pkg::*;
  import actor_verification_pkg::*;

  typedef enum { READ, WRITE } Op_e;

  typedef struct {
    longint unsigned trace;
    int              addr;
    Op_e             op;
    int              data;
  } MemReq_s;

  typedef struct {
    longint unsigned trace;
    int              addr;
    Op_e             op;
    int              data;
    bit              ok;
    bit              from_spec;
  } MemRsp_s;

  // ------------------------------------------------------------------------
  // Random stimulus actor — extends ConstraintActor, publishes every 50 ns
  // ------------------------------------------------------------------------
  class MemStimulus extends ConstraintActor;
    int next_trace = 1;
    int n_total    = 30;
    int n_sent     = 0;

    function new(string name = "MemStimulus");
      super.new(name, 50);
    endfunction

    virtual task randomize_and_publish();
      MemReq_s r;
      if (n_sent >= n_total) begin running = 0; return; end
      r.trace = next_trace++;   // informational only; DiffActor pairs by the envelope trace_id
      r.addr  = $urandom_range(0, 15);
      r.op    = ($urandom_range(0, 1) == 0) ? READ : WRITE;
      r.data  = $urandom_range(0, 255);
      `PUBLISH(r);
      n_sent++;
    endtask
  endclass

  // ------------------------------------------------------------------------
  // MemoryDut — receives requests, produces responses with trace_id preserved
  // ------------------------------------------------------------------------
  class MemoryDut extends Actor;
    int mem[int];
    function new(string name = "MemoryDut"); super.new(name); endfunction

    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(MemReq_s)) begin
        MemReq_s req = Msg#(MemReq_s)::unwrap(msg);
        MemRsp_s rsp;
        rsp.trace     = req.trace;
        rsp.addr      = req.addr;
        rsp.op        = req.op;
        rsp.from_spec = 0;
        if (req.op == WRITE) begin
          mem[req.addr] = req.data;
          rsp.data = req.data;
          rsp.ok   = 1;
        end else begin
          rsp.data = mem.exists(req.addr) ? mem[req.addr] : 0;
          rsp.ok   = 1;
        end
        `PUBLISH_TRACED(rsp, msg);
      end
    endtask
  endclass

  // ------------------------------------------------------------------------
  // SpecMemory — same logic, different actor; should always agree with DUT
  // ------------------------------------------------------------------------
  class SpecMemory extends SpecActor;
    int mem[int];
    function new(string name = "SpecMemory"); super.new(name); endfunction

    virtual function MsgBase compute_response(MsgBase request);
      Msg#(MemRsp_s)  result;
      MemRsp_s        rsp;
      MemReq_s req = Msg#(MemReq_s)::unwrap(request);
      rsp.trace     = req.trace;
      rsp.addr      = req.addr;
      rsp.op        = req.op;
      rsp.from_spec = 1;
      if (req.op == WRITE) begin
        mem[req.addr] = req.data;
        rsp.data = req.data;
      end else begin
        rsp.data = mem.exists(req.addr) ? mem[req.addr] : 0;
      end
      rsp.ok = 1;
      result = new(rsp);
      return result;
    endfunction
  endclass

  // ------------------------------------------------------------------------
  // DUT-vs-Spec diff
  // ------------------------------------------------------------------------
  class MemDiff extends DiffActor;
    function new(string name = "MemDiff"); super.new(name); endfunction

    virtual function bit equal(MsgBase a, MsgBase b);
      MemRsp_s ra = Msg#(MemRsp_s)::unwrap(a);
      MemRsp_s rb = Msg#(MemRsp_s)::unwrap(b);
      return (ra.addr == rb.addr) && (ra.data == rb.data) && (ra.ok == rb.ok);
    endfunction

    virtual function bit is_from_dut(MsgBase msg);
      MemRsp_s r = Msg#(MemRsp_s)::unwrap(msg);
      return (r.from_spec == 0);
    endfunction
  endclass

  // ------------------------------------------------------------------------
  // Coverage actor — extends the package's CoverageActor base. The covergroup
  // stays for full simulators, but Verilator ignores covergroups (COVERIGN,
  // sample() is a no-op), so the same bins are also tracked in plain
  // counters — the summary the demo prints is real on every tool.
  // ------------------------------------------------------------------------
  class MemCoverage extends CoverageActor;
    MemReq_s sample_pkt;
    int op_hits   [2];       // READ, WRITE
    int addr_hits [2];       // lo [0:7], hi [8:15]
    int cross_hits[2][2];    // op x addr

    covergroup cg_mem;
      option.per_instance = 1;
      cp_op:   coverpoint sample_pkt.op;
      cp_addr: coverpoint sample_pkt.addr {
        bins lo  = {[0:7]};
        bins hi  = {[8:15]};
      }
      x_op_addr: cross cp_op, cp_addr;
    endgroup

    function new(string name = "MemCoverage");
      super.new(name);
      cg_mem = new();
    endfunction

    virtual function void sample_one(MsgBase msg);
      int a;
      if (msg.getTypeName() != $typename(MemReq_s)) return;
      sample_pkt = Msg#(MemReq_s)::unwrap(msg);
      cg_mem.sample();
      a = (sample_pkt.addr > 7);
      op_hits[sample_pkt.op]++;
      addr_hits[a]++;
      cross_hits[sample_pkt.op][a]++;
    endfunction

    function int bins_hit();
      int n = 0;
      foreach (op_hits[i])      n += (op_hits[i]      > 0);
      foreach (addr_hits[i])    n += (addr_hits[i]    > 0);
      foreach (cross_hits[i,j]) n += (cross_hits[i][j] > 0);
      return n;
    endfunction
  endclass

endpackage

module tb_top;
  import actor_pkg::*;
  import actor_verification_pkg::*;
  import vdemo_pkg::*;

  MemStimulus  stim;
  MemoryDut    dut;
  SpecMemory   spec;
  MemDiff      diff;
  MemCoverage  cov;

  initial begin
    stim = new();
    dut  = new();
    spec = new();
    diff = new();
    cov  = new();

    // Stimulus publishes MemReq_s — DUT, Spec, and coverage all want it.
    `WIRE(stim, MemReq_s, dut)
    `WIRE(stim, MemReq_s, spec)
    `WIRE(stim, MemReq_s, cov)

    // DUT and Spec both publish MemRsp_s — diff is wired to both.
    `WIRE(dut,  MemRsp_s, diff)
    `WIRE(spec, MemRsp_s, diff)

    // Boot
    diff.start();
    cov.start();
    dut.start();
    spec.start();
    stim.start();

    #3000ns;

    diff.report();
    $display("MemCoverage: %0d samples taken, %0d/8 bins hit (op R=%0d W=%0d; addr lo=%0d hi=%0d)",
             cov.samples_taken, cov.bins_hit(),
             cov.op_hits[READ], cov.op_hits[WRITE],
             cov.addr_hits[0], cov.addr_hits[1]);
`ifndef VERILATOR
    // Verilator discards covergroups; the native figure is meaningful only
    // on full simulators.
    $display("  covergroup: %0.1f%% bins covered", cov.cg_mem.get_inst_coverage());
`endif
    $finish;
  end
endmodule
