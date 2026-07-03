// appB_mini_soc -- runnable Mini-SoC integration as actors (Appendix B).
//
// Two masters (CPU, DMA) and three slaves (Timer, RAL dictionary, AHB->APB
// bridge) around a UbusBfmActor interconnect. With NO virtual sequencer, no
// locked uvm_sequencer, and no four-copy RAL, it demonstrates:
//
//   * Interrupt handling -- the TimerActor fires an IrqMsg_s directly into the
//     CPU's mailbox; the CPU runs the ISR inline in the SAME act() that handles
//     normal bus responses (no sequencer to grab()/ungrab()).
//   * A register file as a plain address-keyed dictionary (RalActor).
//   * Protocol bridging as a single BridgeActor (UbusReq_s -> ApbReq_s).
//   * `WIRE routing by message TYPE; each slave address-decodes its own range.
//
// Build/run:  make     (verilator --binary --timing, then ./obj_dir/Vtb_top)

`timescale 1ns/1ns

package mini_soc_pkg;
  import actor_pkg::*;

  // -------------------------------------------------------------------------
  // Bus contracts (a minimal UBUS subset) and cross-domain contracts.
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] { NOP=0, READ=1, WRITE=2 } ubus_dir_e;

  typedef struct {
    longint      id;
    int          master_id;
    logic [15:0] addr;
    ubus_dir_e   dir;
    logic  [7:0] data;
  } UbusReq_s;

  typedef struct {
    longint     id;
    int         master_id;
    logic [7:0] data;
    logic       error;
  } UbusRsp_s;

  typedef struct { int vector_id; int priority_level; } IrqMsg_s;   // soc_pkg
  typedef struct { logic [31:0] paddr; logic [31:0] pwdata; logic pwrite; } ApbReq_s;

  // -------------------------------------------------------------------------
  // CpuActor -- Master 0. Issues bus writes; one act() handles asynchronous
  // IRQs and normal bus responses (no sequencer to lock for the ISR).
  // -------------------------------------------------------------------------
  class CpuActor extends Actor;
    Actor bfm_target;
    int   master_id = 0;

    function new(string name = "CpuActor"); super.new(name); endfunction

    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(IrqMsg_s)) begin
        IrqMsg_s irq = Msg#(IrqMsg_s)::unwrap(msg);
        $display("[%0t] CpuActor: ASYNC IRQ! vector=%0d -- running ISR...",
                 $time, irq.vector_id);
        #10;  // ISR body
        $display("[%0t] CpuActor: ISR complete.", $time);
      end
      else if (msg.getTypeName() == $typename(UbusRsp_s)) begin
        UbusRsp_s rsp = Msg#(UbusRsp_s)::unwrap(msg);
        if (rsp.master_id == master_id)
          $display("[%0t] CpuActor: bus response data=0x%02h", $time, rsp.data);
      end
    endtask

    task do_write(logic [15:0] addr, logic [7:0] data);
      UbusReq_s req = '{default: '0, master_id: master_id, addr: addr,
                        dir: WRITE, data: data};
      $display("[%0t] CpuActor: WRITE 0x%04h <= 0x%02h", $time, addr, data);
      `PUBLISH_TO(bfm_target, req);
    endtask
  endclass

  // -------------------------------------------------------------------------
  // DmaActor -- Master 1. A burst-write engine; pure producer (empty act()).
  // -------------------------------------------------------------------------
  class DmaActor extends Actor;
    Actor bfm_target;
    int   master_id = 1;

    function new(string name = "DmaActor"); super.new(name); endfunction

    virtual task act(MsgBase msg); endtask  // pure producer

    task burst_write(logic [15:0] base, logic [7:0] data, int len);
      $display("[%0t] DmaActor: burst write len=%0d @ 0x%04h", $time, len, base);
      for (int i = 0; i < len; i++) begin
        UbusReq_s req = '{default: '0, master_id: master_id,
                          addr: base + 16'(i), dir: WRITE, data: data};
        `PUBLISH_TO(bfm_target, req);
        #5;
      end
    endtask
  endclass

  // -------------------------------------------------------------------------
  // TimerActor -- peripheral at 0x1000. A bus write loads the countdown; a
  // background loop counts down and fires an IrqMsg_s straight into the CPU.
  // -------------------------------------------------------------------------
  class TimerActor extends Actor;
    Actor cpu_target;
    int   timer_count;
    bit   timer_running = 0;

    function new(Actor cpu, string name = "TimerActor");
      super.new(name);
      cpu_target = cpu;
    endfunction

    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(UbusReq_s)) begin
        UbusReq_s req = Msg#(UbusReq_s)::unwrap(msg);
        if (req.addr == 16'h1000 && req.dir == WRITE) begin
          timer_count   = int'(req.data);
          timer_running = 1;
          $display("[%0t] TimerActor: armed, count=%0d", $time, timer_count);
        end
      end
    endtask

    virtual task run_counter();
      forever begin
        #10;
        if (timer_running) begin
          timer_count--;
          if (timer_count <= 0) begin
            IrqMsg_s irq = '{vector_id: 8, priority_level: 1};
            timer_running = 0;
            $display("[%0t] TimerActor: expired -- firing IRQ to CPU", $time);
            `PUBLISH_TO(cpu_target, irq);
          end
        end
      end
    endtask

    // start() forks run(); we fork the countdown alongside the act() loop.
    virtual task run();
      fork run_counter(); join_none
      super.run();
    endtask
  endclass

  // -------------------------------------------------------------------------
  // RalActor -- register file as an address-keyed dictionary. Stores direct
  // UBUS register writes (0x2000-0x3FFF) and bridged APB writes; read_reg is
  // a backdoor peek for the testbench (bypasses the bus).
  // -------------------------------------------------------------------------
  class RalActor extends Actor;
    protected logic [31:0] memory_map [int];

    function new(string name = "RalActor"); super.new(name); endfunction

    function logic [31:0] read_reg(int addr);   // backdoor peek
      return memory_map.exists(addr) ? memory_map[addr] : 32'h0;
    endfunction

    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(UbusReq_s)) begin
        UbusReq_s req = Msg#(UbusReq_s)::unwrap(msg);
        if (req.dir == WRITE && req.addr >= 16'h2000 && req.addr <= 16'h3FFF)
          memory_map[int'(req.addr)] = 32'(req.data);
      end
      else if (msg.getTypeName() == $typename(ApbReq_s)) begin
        ApbReq_s apb = Msg#(ApbReq_s)::unwrap(msg);
        if (apb.pwrite) memory_map[apb.paddr] = apb.pwdata;
      end
    endtask

    function void dump();
      $display("--- RAL final state ---");
      foreach (memory_map[a])
        $display("  [0x%04h] = 0x%02h", a, memory_map[a]);
    endfunction
  endclass

  // -------------------------------------------------------------------------
  // BridgeActor -- AHB->APB bridge. Decodes 0x4000-0x4FFF, translates a UBUS
  // write into an ApbReq_s, and forwards it to its APB target (the RAL).
  // -------------------------------------------------------------------------
  class BridgeActor extends Actor;
    Actor apb_target;

    function new(string name = "BridgeActor"); super.new(name); endfunction

    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(UbusReq_s)) begin
        UbusReq_s ubus_in = Msg#(UbusReq_s)::unwrap(msg);
        if (ubus_in.dir == WRITE && ubus_in.addr >= 16'h4000
                                 && ubus_in.addr <= 16'h4FFF) begin
          ApbReq_s apb_out;
          apb_out.paddr  = {16'h0000, ubus_in.addr};
          apb_out.pwdata = {24'h000000, ubus_in.data};
          apb_out.pwrite = 1;
          `PUBLISH_TO(apb_target, apb_out);
        end
      end
    endtask
  endclass

  // -------------------------------------------------------------------------
  // UbusBfmActor -- the interconnect. Masters PUBLISH_TO it; it fans each
  // request out to the wired slaves (by type) and publishes a response,
  // which reaches the masters wired for UbusRsp_s (they filter by master_id).
  // -------------------------------------------------------------------------
  class UbusBfmActor extends Actor;
    function new(string name = "UbusBfmActor"); super.new(name); endfunction

    virtual task act(MsgBase msg);
      if (msg.getTypeName() == $typename(UbusReq_s)) begin
        UbusReq_s req = Msg#(UbusReq_s)::unwrap(msg);
        UbusRsp_s rsp = '{default: '0, master_id: req.master_id,
                          data: req.data, error: 0};
        publish(msg);            // fan the request out to the wired slaves
        `PUBLISH_TRACED(rsp, msg);  // response inherits the request's trace lineage
      end
    endtask
  endclass

  // -------------------------------------------------------------------------
  // SocEnvActor -- builds and wires the SoC. No virtual sequencer.
  // -------------------------------------------------------------------------
  class SocEnvActor extends Actor;
    CpuActor      cpu;
    DmaActor      dma;
    TimerActor    timer;
    RalActor      ral;
    BridgeActor   bridge;
    UbusBfmActor  bfm;

    function new(string name = "SocEnvActor");
      super.new(name);
      bfm    = new("UbusBfmActor");
      cpu    = new("CpuActor");    cpu.bfm_target = bfm;
      dma    = new("DmaActor");    dma.bfm_target = bfm;
      timer  = new(cpu, "TimerActor");
      ral    = new("RalActor");
      bridge = new("BridgeActor"); bridge.apb_target = ral;

      // `WIRE routes by message TYPE: every UbusReq_s subscriber sees every
      // bus write, so each slave address-decodes the range it owns inside
      // act(). The CPU wires for the response type. Masters inject requests
      // with `PUBLISH_TO directly into the interconnect's mailbox.
      `WIRE(bfm, UbusReq_s, timer)
      `WIRE(bfm, UbusReq_s, ral)
      `WIRE(bfm, UbusReq_s, bridge)
      `WIRE(bfm, UbusRsp_s, cpu)
    endfunction

    function void start_all();
      bfm.start(); cpu.start(); dma.start();
      timer.start(); ral.start(); bridge.start();
    endfunction
  endclass

endpackage

module tb_top;
  import actor_pkg::*;
  import mini_soc_pkg::*;

  SocEnvActor env;

  initial begin
    env = new();
    env.start_all();

    $display("\n=== Mini-SoC: CPU + DMA masters, Timer/RAL/Bridge slaves ===\n");

    // CPU arms the timer (30 ticks) and does a normal register write.
    env.cpu.do_write(16'h1000, 8'd30);   // configure timer
    env.cpu.do_write(16'h2000, 8'hbb);   // register write -> RAL

    #150;
    // DMA bursts two beats into the bridge's APB-mapped window.
    env.dma.burst_write(16'h4000, 8'haa, 2);

    #400;   // let the timer expire and the ISR run

    $display("");
    env.ral.dump();
    $display("\n=== Mini-SoC complete ===");
    $finish;
  end
endmodule
