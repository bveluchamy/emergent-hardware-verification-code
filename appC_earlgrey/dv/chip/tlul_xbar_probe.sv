// tlul_xbar_probe.sv
//
// SystemVerilog `bind`-bound module that snoops a TL-UL master port on
// OpenTitan's xbar_main without modifying any RTL. The probe samples the
// a/d channels each clock and writes observed transactions into a static
// queue in ot_dv_probe_pkg, where an actor-side reader (ProbeForwardActor)
// drains them and re-publishes as RalEvent_s through the actor framework.
//
// The probe is non-invasive: it only reads tl_h2d / tl_d2h. No RTL is
// modified -- the upstream OpenTitan tree stays unchanged.
//
// Usage in the testbench top:
//
//   bind xbar_main tlul_xbar_probe #(.PROBE_NAME("main.cored")) u_probe_cored (
//     .clk_i,
//     .rst_ni,
//     .tl_h2d (tl_rv_core_ibex__cored_i),
//     .tl_d2h (tl_rv_core_ibex__cored_o)
//   );

`timescale 1ns/1ps

module tlul_xbar_probe
  import tlul_pkg::*;
  import ot_dv_pkg::*;
#(
  parameter string PROBE_NAME = "unnamed"
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  tl_h2d_t    tl_h2d,
  input  tl_d2h_t    tl_d2h
);

  // Pending a-channel transactions awaiting their d-channel response,
  // keyed by source ID (a_source).
  OtTlulTxn_s pending [logic [7:0]];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending.delete();
    end else begin
      // a-channel handshake: master fires, slave accepts.
      if (tl_h2d.a_valid && tl_d2h.a_ready) begin
        OtTlulTxn_s t;
        t.probe_name = PROBE_NAME;
        case (tl_h2d.a_opcode)
          PutFullData:    t.a_opcode = OT_TL_PUT_FULL_DATA;
          PutPartialData: t.a_opcode = OT_TL_PUT_PARTIAL_DATA;
          default:        t.a_opcode = OT_TL_GET;
        endcase
        t.addr      = tl_h2d.a_address;
        t.wdata     = tl_h2d.a_data;
        t.wstrb     = tl_h2d.a_mask;
        t.source_id = tl_h2d.a_source;
        t.a_time_ns = $time;
        pending[tl_h2d.a_source] = t;
      end

      // d-channel handshake: slave fires, master accepts.
      if (tl_d2h.d_valid && tl_h2d.d_ready) begin
        if (pending.exists(tl_d2h.d_source)) begin
          OtTlulTxn_s t = pending[tl_d2h.d_source];
          case (tl_d2h.d_opcode)
            AccessAckData: t.d_opcode = OT_TL_ACCESS_ACK_DATA;
            default:       t.d_opcode = OT_TL_ACCESS_ACK;
          endcase
          t.rdata     = tl_d2h.d_data;
          t.error     = tl_d2h.d_error;
          t.d_time_ns = $time;
          ot_dv_probe_pkg::push_txn(t);
          pending.delete(tl_d2h.d_source);
        end
      end
    end
  end

endmodule
