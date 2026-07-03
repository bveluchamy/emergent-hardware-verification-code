// reset_pkg.sv
//
// OpenTitan multi-domain reset event contracts.
//
// In silicon, OpenTitan has multiple reset domains (system, lifecycle,
// always-on, security) that can be asserted independently. UVM testbenches
// model this with phase-jumping which is fragile. Actors model it as
// regular messages flowing through the topology.
//
// The reset supervisor in ot_supervisor_actor.sv is the central authority:
// it consumes ResetReq_s (from pwrmgr, alert_handler, JTAG, etc.) and
// publishes ResetEvent_s downstream so each IP actor restarts its own
// state cleanly.

package reset_pkg;

  typedef enum logic [2:0] {
    RST_NONE       = 0,
    RST_LIFECYCLE  = 1,   // lc_ctrl-driven
    RST_SYSTEM     = 2,   // sw or alert_handler-driven full system reset
    RST_AON        = 3,   // always-on domain reset (pwrmgr)
    RST_DEBUG      = 4,   // JTAG-initiated reset
    RST_GLITCH     = 5,   // fault-injection / lockstep glitch
    RST_CHIP       = 6    // full chip reset (POR-class)
  } reset_kind_e;

  typedef struct {
    reset_kind_e   kind;
    string         requester;      // e.g. "pwrmgr", "alert_handler.classA"
    string         reason;         // human-readable
    longint unsigned timestamp_ns;
  } ResetReq_s;

  // Broadcast: "domain X is now in reset/out-of-reset"
  typedef struct {
    reset_kind_e   kind;
    bit            asserted;       // 1 = entering reset; 0 = leaving
    longint unsigned timestamp_ns;
  } ResetEvent_s;

endpackage
