// lc_ctrl_pkg.sv  --  Earlgrey lifecycle controller messages.
//
// lc_ctrl is the security-critical state machine that tracks the chip's
// lifecycle (RAW -> TEST_UNLOCKED -> DEV/PROD/RMA/SCRAP). State
// transitions are protected by transition tokens stored in OTP. Once
// the chip is in SCRAP, it stays there permanently.
//
// In OpenTitan UVM, lc_ctrl_env is one of the larger DV environments
// (~5,300 lines) precisely because verifying a security-critical FSM
// against tampered transitions is hard. The actor-model version
// shrinks the verification *infrastructure* but preserves all the
// stimulus and check logic the security testing requires.

package lc_ctrl_pkg;
  import earlgrey_memory_map_pkg::*;

  typedef enum logic [3:0] {
    LC_TX_PROGRAM    = 0,   // burn fuses to enter next state
    LC_TX_VOLATILE   = 1    // soft (volatile) transition for testing
  } lc_tx_kind_e;

  // SW (or test) requests a transition
  typedef struct {
    lc_tx_kind_e   kind;
    eg_lc_state_e  target_state;
    logic [127:0]  token;          // unlock token
    longint unsigned timestamp_ns;
  } LcTransitionReq_s;

  // lc_ctrl publishes after attempting a transition
  typedef struct {
    eg_lc_state_e  prev_state;
    eg_lc_state_e  next_state;
    bit            success;
    string         failure_reason;     // if !success
    longint unsigned timestamp_ns;
  } LcTransitionResult_s;

endpackage
