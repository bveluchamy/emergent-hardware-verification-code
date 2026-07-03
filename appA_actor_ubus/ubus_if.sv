// Faithful port of the UVM UBUS interface signals to the Actor framework.
// Matches dut_dummy.v's port list exactly, using [15:0] buses for
// request/grant so both masters use the same shared interface.

interface ubus_if;
  logic        sig_clock;
  logic        sig_reset;
  logic [15:0] sig_request;  // Bit-indexed by master_id (only [0] and [1] used)
  logic [15:0] sig_grant;    // Driven by DUT arbiter per master_id
  logic [15:0] sig_addr;
  logic  [1:0] sig_size;
  logic        sig_read;
  logic        sig_write;
  logic        sig_start;    // Driven by DUT arbiter
  logic        sig_bip;      // Bus-in-progress, driven by master
  wire  logic  [7:0] sig_data;
  logic  [7:0] sig_data_out;
  logic        sig_wait;     // Driven by slave
  logic        sig_error;    // Driven by slave

  logic        rw;           // Controls bi-directional sig_data driver
  assign sig_data = rw ? sig_data_out : 8'bz;

  // Synchronous timing domain for testbench components
  clocking cb @(posedge sig_clock);
    default input #1step output #1ns;
    inout sig_request;
    inout sig_grant;
    inout sig_addr;
    inout sig_size;
    inout sig_read;
    inout sig_write;
    inout sig_start;
    inout sig_bip;
    inout sig_data;
    inout sig_data_out;
    inout sig_wait;
    inout sig_error;
    inout rw;
  endclocking

  // Safe initial state
  initial begin
    sig_request  = '0;
    sig_data_out = '0;
    sig_size     = '0;
    sig_read     = '0;
    sig_write    = '0;
    sig_bip      = '0;
    rw           = '0;
  end
endinterface
