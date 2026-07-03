// tlul_if.sv
//
// SystemVerilog interface for TL-UL pin-level signals. All TL-UL actors
// (master, slave, monitor, xbar) bind to a virtual handle of this
// interface. The exact wire shape mirrors the OpenTitan TL-UL spec
// (subset; we do not model TL-C / coherence).

interface tlul_if(input logic clk_i, input logic rst_ni);
  import tlul_pkg::*;

  // A-channel (host -> device)
  logic                  a_valid;
  logic                  a_ready;
  logic [2:0]            a_opcode;
  logic [TL_SZW-1:0]     a_size;
  logic [TL_AW-1:0]      a_addr;
  logic [TL_DW-1:0]      a_data;
  logic [TL_BW-1:0]      a_mask;
  logic [TL_AIW-1:0]     a_source;

  // D-channel (device -> host)
  logic                  d_valid;
  logic                  d_ready;
  logic [2:0]            d_opcode;
  logic [TL_SZW-1:0]     d_size;
  logic [TL_DW-1:0]      d_data;
  logic                  d_error;
  logic [TL_AIW-1:0]     d_source;

  modport host_mp   (input clk_i, rst_ni, a_ready, d_valid, d_opcode, d_size, d_data, d_error, d_source,
                     output a_valid, a_opcode, a_size, a_addr, a_data, a_mask, a_source, d_ready);
  modport device_mp (input clk_i, rst_ni, a_valid, a_opcode, a_size, a_addr, a_data, a_mask, a_source, d_ready,
                     output a_ready, d_valid, d_opcode, d_size, d_data, d_error, d_source);
  modport monitor_mp(input clk_i, rst_ni, a_valid, a_ready, a_opcode, a_size, a_addr, a_data, a_mask, a_source,
                              d_valid, d_ready, d_opcode, d_size, d_data, d_error, d_source);
endinterface
