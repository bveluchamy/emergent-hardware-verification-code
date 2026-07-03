// rstmgr_pkg.sv  --  Earlgrey reset manager messages.
//
// rstmgr_aon owns the chip's reset domain hierarchy. It receives reset
// requests (from pwrmgr, alert_handler, sysrst_ctrl, JTAG, SW) and
// drives the right reset-domain output signals to every IP, holding
// each reset for the appropriate number of cycles.
//
// In the actor model, this is just a subscriber-publisher: it consumes
// ResetReq_s from any source and publishes ResetEvent_s out, with the
// reset-reason and domain information attached.

package rstmgr_pkg;
  import earlgrey_memory_map_pkg::*;

  // Reset reason -- what caused the last reset
  typedef enum logic [3:0] {
    RST_REASON_POR        = 0,   // power-on reset
    RST_REASON_LOW_POWER  = 1,   // wakeup from sleep
    RST_REASON_SW         = 2,   // SW-issued
    RST_REASON_HW         = 3,   // hardware (alert escalation, sysrst)
    RST_REASON_NDM        = 4,   // JTAG non-debug-module reset
    RST_REASON_SYSRST     = 5    // sysrst_ctrl-driven
  } rst_reason_e;

  // Captured at the time of reset; readable after wakeup
  typedef struct {
    rst_reason_e        reason;
    eg_reset_domain_e   domain;
    string              requester;
    longint unsigned    timestamp_ns;
  } RstReasonRecord_s;

endpackage
