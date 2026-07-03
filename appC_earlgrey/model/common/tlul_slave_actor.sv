// tlul_slave_actor.sv
//
// Generic TL-UL slave BFM. Owns an address range, services GET/PUT_FULL/
// PUT_PARTIAL transactions, and responds with ACCESS_ACK / ACCESS_ACK_DATA.
//
// In an OpenTitan IP DV environment the slave is typically the DUT itself
// (the IP being verified). For the actor framework, we cleanly separate
// "the protocol responder" (this actor) from "the register file backing
// store" (the RalActor). The slave actor handles wire timing; the
// responder it forwards to handles protocol semantics.
//
// Subscribers can be:
//   * The IP-under-test's RalActor (real register file)
//   * A reference model actor (golden behavior)
//   * The bus monitor
//
// In simple per-IP testbenches, the slave actor IS the DUT model, and
// the RalActor lives in the test infrastructure to verify expected
// register state matches.

import actor_pkg::*;
import tlul_pkg::*;

class TlulSlaveActor extends Actor;
  virtual interface tlul_if vif;
  logic [TL_AW-1:0]         base_addr;
  logic [TL_AW-1:0]         addr_mask;     // OpenTitan uses MMIO-region alignments

  // Backing store: simple address-keyed dictionary (the RalActor pattern)
  logic [TL_DW-1:0]         mem [logic [TL_AW-1:0]];

  function new(virtual tlul_if vif,
               logic [TL_AW-1:0] base_addr,
               logic [TL_AW-1:0] addr_mask,
               string name = "TlulSlaveActor");
    super.new(name);
    this.vif       = vif;
    this.base_addr = base_addr;
    this.addr_mask = addr_mask;
  endfunction

  // The slave actor uses run() (not act()) because it needs to drive
  // pin-level wires off the clock, not react to mailbox messages. This
  // is the pattern for every "DUT-side responder" actor in the example.
  virtual task run();
    vif.a_ready <= 1'b0;
    vif.d_valid <= 1'b0;
    forever begin
      @(posedge vif.clk_i);
      if (!vif.rst_ni) begin
        vif.a_ready <= 1'b1;
        vif.d_valid <= 1'b0;
        continue;
      end
      vif.a_ready <= 1'b1;
      if (vif.a_valid) begin
        // Address decode: only respond if hit
        if ((vif.a_addr & addr_mask) == base_addr) begin
          handle_request();
        end
      end
    end
  endtask

  task handle_request();
    logic [TL_AW-1:0]  addr   = vif.a_addr;
    logic [TL_DW-1:0]  wdata  = vif.a_data;
    tl_a_op_e          opcode = tl_a_op_e'(vif.a_opcode);
    logic [TL_SZW-1:0] size   = vif.a_size;
    logic [TL_AIW-1:0] src    = vif.a_source;

    // Simulate one cycle of access latency
    @(posedge vif.clk_i);

    case (opcode)
      TL_PUT_FULL, TL_PUT_PARTIAL: begin
        mem[addr] = wdata;
        vif.d_opcode <= TL_ACCESS_ACK;
        vif.d_data   <= '0;
      end
      TL_GET: begin
        vif.d_opcode <= TL_ACCESS_ACK_DATA;
        vif.d_data   <= mem.exists(addr) ? mem[addr] : '0;
      end
      default: begin
        vif.d_opcode <= TL_ACCESS_ACK;
        vif.d_data   <= '0;
      end
    endcase
    vif.d_size   <= size;
    vif.d_source <= src;
    vif.d_error  <= 1'b0;
    vif.d_valid  <= 1'b1;

    // Wait for host to accept the response
    do @(posedge vif.clk_i); while (vif.d_ready !== 1'b1);
    vif.d_valid  <= 1'b0;
  endtask
endclass
