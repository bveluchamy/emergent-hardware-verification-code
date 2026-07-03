// keymgr_pkg.sv  --  Earlgrey key manager messages.
//
// keymgr is a state-machine that derives keys from OTP seeds + flash
// seeds + lifecycle state, advancing through stages:
//   RESET -> INIT -> CREATOR_ROOT_KEY -> OWNER_INT_KEY -> OWNER_KEY -> DISABLED

package keymgr_pkg;

  typedef enum logic [3:0] {
    KEYMGR_RESET             = 0,
    KEYMGR_INIT              = 1,
    KEYMGR_CREATOR_ROOT_KEY  = 2,
    KEYMGR_OWNER_INT_KEY     = 3,
    KEYMGR_OWNER_KEY         = 4,
    KEYMGR_DISABLED          = 5,
    KEYMGR_INVALID           = 6
  } keymgr_state_e;

  // Stage advance request from SW
  typedef struct {
    longint unsigned timestamp_ns;
  } KeymgrAdvanceReq_s;

  typedef struct {
    keymgr_state_e   prev_state;
    keymgr_state_e   next_state;
    logic [255:0]    derived_key;       // derived from KMAC(internal_key, salt)
    bit              success;
    string           failure_reason;
    longint unsigned timestamp_ns;
  } KeymgrAdvanceResult_s;

  // SW-issued generate request: produce an output key for a sealing key
  typedef struct {
    string           dest;       // "aes" / "kmac" / "otbn" / "sw"
    logic [255:0]    salt;
    longint unsigned timestamp_ns;
  } KeymgrGenReq_s;

  typedef struct {
    string           dest;
    logic [255:0]    output_key;
    longint unsigned timestamp_ns;
  } KeymgrGenResult_s;

endpackage
