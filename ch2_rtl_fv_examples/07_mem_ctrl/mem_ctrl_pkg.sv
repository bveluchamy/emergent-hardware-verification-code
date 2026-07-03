package mem_ctrl_pkg;
  // Default sizing + timing (override per-instance as needed)
  parameter int ADDR_W         = 12;     // 4K-entry backing store
  parameter int DATA_W         = 32;
  parameter int REFRESH_PERIOD = 8192;   // tREFI (cycles between refreshes)
  parameter int TRFC           = 100;    // refresh duration (cycles)
  parameter int TRAS           = 50;     // row activate hold (cycles)

  // FSM states
  typedef enum logic [2:0] {
    IDLE, ACTIVATING, ACTIVE, PRECHARGING, REFRESHING
  } state_e;

  // Operation type
  typedef enum logic { OP_READ = 1'b0, OP_WRITE = 1'b1 } op_e;

  // Command transaction
  typedef struct packed {
    logic                 valid;
    op_e                  op;
    logic [ADDR_W-1:0]    addr;
    logic [DATA_W-1:0]    data;
  } cmd_t;

  // Response transaction
  typedef struct packed {
    logic                 valid;
    logic [DATA_W-1:0]    data;
  } rsp_t;
endpackage : mem_ctrl_pkg
