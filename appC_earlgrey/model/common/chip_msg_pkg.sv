// chip_msg_pkg.sv
//
// Cross-IP messages used at SoC integration scale, beyond the per-protocol
// contracts in tlul_pkg / irq_pkg / alert_pkg / reset_pkg.
//
// These appear when verifying interactions between IPs at the chip-level
// testbench (the OpenTitan chip_sw_* equivalent). They are not part of any
// single IP's interface; they exist so chip-level scoreboard / coverage
// actors can subscribe to high-level system events without each IP
// needing to publish them in a special form.

package chip_msg_pkg;

  // Power state changes (pwrmgr -> world)
  typedef enum logic [2:0] {
    POWER_ACTIVE       = 0,
    POWER_LOW_POWER    = 1,
    POWER_DEEP_SLEEP   = 2,
    POWER_RESET        = 3
  } power_state_e;

  typedef struct {
    power_state_e prev_state;
    power_state_e next_state;
    string        requester;
    longint unsigned timestamp_ns;
  } PowerStateChange_s;

  // Lifecycle state changes (lc_ctrl -> world)
  typedef enum logic [3:0] {
    LC_TEST_UNLOCKED   = 0,
    LC_DEV             = 1,
    LC_PROD            = 2,
    LC_RMA             = 3,
    LC_SCRAP           = 4
  } lc_state_e;

  typedef struct {
    lc_state_e    prev_state;
    lc_state_e    next_state;
    longint unsigned timestamp_ns;
  } LifecycleChange_s;

  // Lockstep comparator (Ibex pair)
  typedef struct {
    longint unsigned cycle;
    string         field;            // e.g. "pc", "rd_data", "instr"
    longint unsigned core_a_value;
    longint unsigned core_b_value;
  } LockstepMismatch_s;

  // CPU instruction trace (per Ibex core)
  typedef struct {
    int                  core_id;       // 0 or 1 in lockstep pair
    longint unsigned     cycle;
    logic [31:0]         pc;
    logic [31:0]         instr;
  } InstrTrace_s;

  // Generic chip-level event for end-of-test / progress markers
  typedef struct {
    string  tag;
    string  detail;
    longint unsigned timestamp_ns;
  } ChipEvent_s;

endpackage
