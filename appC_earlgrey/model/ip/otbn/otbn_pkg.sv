// otbn_pkg.sv  --  Earlgrey OTBN (OpenTitan Big Number) accelerator.
//
// OTBN is an in-order RISC-V-extension processor for asymmetric crypto
// (RSA, ECC, post-quantum). It has its own DMEM (data memory), IMEM
// (instruction memory), 32 GPR + 32 wide-data registers (256-bit), and
// runs SW-loaded programs at the request of the CPU.

package otbn_pkg;

  parameter int unsigned EG_OTBN_DMEM_BYTES = 4096;
  parameter int unsigned EG_OTBN_IMEM_BYTES = 4096;

  typedef enum logic [3:0] {
    OTBN_STATE_IDLE       = 0,
    OTBN_STATE_BUSY       = 1,
    OTBN_STATE_LOCKED     = 2,
    OTBN_STATE_FAULT      = 3
  } otbn_state_e;

  // SW writes a region of IMEM or DMEM (CSR access)
  typedef enum logic [0:0] {
    OTBN_REGION_IMEM = 0,
    OTBN_REGION_DMEM = 1
  } otbn_region_e;

  typedef struct {
    otbn_region_e        region;
    int                  word_offset;
    logic [31:0]         data;
    longint unsigned     timestamp_ns;
  } OtbnMemWrite_s;

  typedef struct {
    otbn_region_e        region;
    int                  word_offset;
    longint unsigned     timestamp_ns;
  } OtbnMemReadReq_s;

  typedef struct {
    otbn_region_e        region;
    int                  word_offset;
    logic [31:0]         data;
    longint unsigned     timestamp_ns;
  } OtbnMemReadRsp_s;

  // SW kicks off a program
  typedef struct {
    int                  start_pc;        // word offset in IMEM
    longint unsigned     timestamp_ns;
  } OtbnExecReq_s;

  // OTBN publishes when the program completes
  typedef struct {
    bit                  success;
    string               failure_reason;
    int                  cycles_taken;
    longint unsigned     timestamp_ns;
  } OtbnExecDone_s;

  // OTBN publishes its FSM state on every transition
  typedef struct {
    otbn_state_e         prev_state;
    otbn_state_e         next_state;
    longint unsigned     timestamp_ns;
  } OtbnStateChange_s;

endpackage
