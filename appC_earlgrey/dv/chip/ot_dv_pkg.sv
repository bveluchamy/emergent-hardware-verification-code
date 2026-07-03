// ot_dv_pkg.sv
//
// Packet types for the dv (real-RTL) testbench. Bus traffic observed via
// SystemVerilog bind probes onto the chip's internal xbar is published as
// these structs into the actor framework, where the same RAL / scoreboard /
// coverage actors used by the model dv consume them.

package ot_dv_pkg;

  // Mirror of OpenTitan's tlul_pkg::tl_a_op_e for use in actor messages
  // without dragging the OT package into framework headers.
  typedef enum logic [2:0] {
    OT_TL_PUT_FULL_DATA    = 3'h0,
    OT_TL_PUT_PARTIAL_DATA = 3'h1,
    OT_TL_GET              = 3'h4
  } ot_tl_a_op_e;

  typedef enum logic [2:0] {
    OT_TL_ACCESS_ACK       = 3'h0,
    OT_TL_ACCESS_ACK_DATA  = 3'h1
  } ot_tl_d_op_e;

  // Observed bus transaction. Published once per a-channel handshake on
  // the probe point, with the d-channel response merged in once the slave
  // returns it. The probe correlates a/d channels by source ID.
  typedef struct {
    string             probe_name;     // which probe saw it (e.g. "main.cored")
    ot_tl_a_op_e       a_opcode;
    ot_tl_d_op_e       d_opcode;
    logic [31:0]       addr;
    logic [31:0]       wdata;          // valid when a_opcode is PUT_*
    logic [31:0]       rdata;          // valid when d_opcode is ACCESS_ACK_DATA
    logic [3:0]        wstrb;
    logic [7:0]        source_id;
    longint unsigned   a_time_ns;
    longint unsigned   d_time_ns;
    bit                error;          // d-channel d_error
  } OtTlulTxn_s;

  // Pin-level UART tx edge.
  typedef struct {
    longint unsigned   timestamp_ns;
    bit                level;
  } OtUartPinEdge_s;

  // Pin-level GPIO output transition.
  typedef struct {
    longint unsigned   timestamp_ns;
    logic [31:0]       value;
    logic [31:0]       enable_mask;
  } OtGpioPinTransition_s;

endpackage
