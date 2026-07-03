// aon_timer_pkg.sv
//
// Always-on timer message contracts. The OpenTitan AON timer runs in a
// separate clock domain (always-on, low-frequency) and continues counting
// even when the main domain is in deep sleep.
//
// Verifying it stresses cross-clock-domain checking. UVM models this with
// multiple monitors on different clocks plus careful CDC-aware scoreboard
// reconstruction. The actor model handles it natively because each actor
// has its own thread and mailboxes don't care about clock domains -- a
// publish from an AON-domain actor lands in a main-domain actor's mailbox
// the same as any other message.

package aon_timer_pkg;

  typedef enum logic [1:0] {
    AON_TIMER_WKUP        = 0,
    AON_TIMER_BARK        = 1,
    AON_TIMER_BITE        = 2
  } aon_timer_event_e;

  typedef struct {
    int                  prescaler;
    longint unsigned     wkup_threshold;
    longint unsigned     bark_threshold;     // watchdog warning
    longint unsigned     bite_threshold;     // watchdog kill
    bit                  wkup_enable;
    bit                  wdog_enable;
    bit                  pause_in_sleep;
  } AonTimerConfig_s;

  typedef struct {
    aon_timer_event_e    kind;
    longint unsigned     count_value;
    longint unsigned     timestamp_ns;
  } AonTimerEvent_s;

  typedef struct {
    longint unsigned     wkup_count;
    longint unsigned     wdog_count;
    longint unsigned     timestamp_ns;
  } AonTimerTick_s;

endpackage
