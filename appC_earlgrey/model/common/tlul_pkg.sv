// tlul_pkg.sv
//
// TileLink Uncached Lightweight (TL-UL) message types for the
// OpenTitan-as-actors example.
//
// TL-UL is the bus every OpenTitan IP exposes for register access. It has
// a request channel A (host -> device) and a response channel D
// (device -> host) with explicit ready/valid handshakes per channel.
//
// The actor framework models the protocol by sending one struct per
// transaction. A master actor publishes TlulReq_s; the slave/interconnect
// publishes TlulRsp_s back. Bus monitors publish TlulMonPkt_s for
// scoreboards/coverage/tracers to subscribe to.
//
// This file is the message contract. It is the equivalent of the TL-UL
// transaction class in OpenTitan's UVM tl_agent, but with no behavior --
// just plain data types. Behavior lives in the master/slave/xbar actors
// that consume and produce these structs.

package tlul_pkg;

  // TileLink "A" channel opcodes (subset used by TL-UL)
  typedef enum logic [2:0] {
    TL_GET           = 3'd4,  // read
    TL_PUT_FULL      = 3'd0,  // write whole word
    TL_PUT_PARTIAL   = 3'd1,  // write with byte mask
    TL_OP_INVALID    = 3'd7
  } tl_a_op_e;

  // TileLink "D" channel opcodes (subset)
  typedef enum logic [2:0] {
    TL_ACCESS_ACK      = 3'd0,  // write completion, no data
    TL_ACCESS_ACK_DATA = 3'd1,  // read completion with data
    TL_D_OP_INVALID    = 3'd7
  } tl_d_op_e;

  parameter int unsigned TL_AW = 32;  // address width
  parameter int unsigned TL_DW = 32;  // data width
  parameter int unsigned TL_BW = TL_DW / 8;
  parameter int unsigned TL_SZW = 2;  // log2 of byte size encoding (1,2,4)
  parameter int unsigned TL_AIW = 8;  // master id width (a_source)

  // Request from master to interconnect
  typedef struct {
    longint unsigned     id;            // unique transaction id (testbench-side)
    int                  master_id;     // which master originated this
    tl_a_op_e            opcode;
    logic [TL_SZW-1:0]   size;          // 0=1B, 1=2B, 2=4B
    logic [TL_AW-1:0]    addr;
    logic [TL_DW-1:0]    data;          // valid for PUT_FULL/PUT_PARTIAL
    logic [TL_BW-1:0]    mask;          // byte enables for PUT_PARTIAL
    logic [TL_AIW-1:0]   a_source;      // wire-level master id
  } TlulReq_s;

  // Response from interconnect/slave back to master
  typedef struct {
    longint unsigned     id;            // matches the originating req.id
    int                  master_id;     // which master this response is for
    tl_d_op_e            opcode;
    logic [TL_SZW-1:0]   size;
    logic [TL_AW-1:0]    addr;          // echoed for convenience
    logic [TL_DW-1:0]    data;          // valid for ACCESS_ACK_DATA
    logic                error;         // d_error
    logic [TL_AIW-1:0]   d_source;      // echoed master id
  } TlulRsp_s;

  // Passive bus monitor publishes one of these per observed transaction
  // (request paired with its eventual response). Scoreboard, coverage,
  // and tracer actors are all `WIRE'd for these.
  typedef struct {
    longint unsigned     id;
    int                  master_id;
    tl_a_op_e            a_opcode;
    tl_d_op_e            d_opcode;
    logic [TL_AW-1:0]    addr;
    logic [TL_DW-1:0]    wdata;         // for writes
    logic [TL_DW-1:0]    rdata;         // for reads
    logic [TL_BW-1:0]    mask;
    logic                error;
    longint unsigned     latency_cycles; // cycle count from req to rsp
  } TlulMonPkt_s;

endpackage
