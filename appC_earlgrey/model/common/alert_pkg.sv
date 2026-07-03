// alert_pkg.sv
//
// OpenTitan alert/escalation message contracts.
//
// OpenTitan's alert_handler runs four parallel "escalation classes" (A/B/C/D),
// each with a 4-phase timer. Every IP can raise alerts that are routed to
// the alert_handler, which decides which class an alert belongs to and
// progresses through the per-class escalation phases. Each phase can fire
// a different action: NMI to the CPU, lifecycle scrap, power reset, chip reset.
//
// Modeling all of this with classes-and-phases in UVM is awkward because
// the four classes are concurrent and the handler is itself a state
// machine running in parallel with everything else. With actors, each
// class is just one FsmActor instance, and each escalation action is a
// subscriber actor.

package alert_pkg;

  typedef enum logic [1:0] { CLASS_A = 0, CLASS_B = 1, CLASS_C = 2, CLASS_D = 3 } esc_class_e;
  typedef enum logic [1:0] { PHASE_0 = 0, PHASE_1 = 1, PHASE_2 = 2, PHASE_3 = 3 } esc_phase_e;
  typedef enum logic [1:0] { STATE_IDLE = 0, STATE_TIMING = 1, STATE_TERMINAL = 2, STATE_FSM_ERROR = 3 } esc_state_e;

  // Action that fires at a particular escalation phase
  typedef enum logic [2:0] {
    ESC_NONE          = 0,
    ESC_NMI           = 1,  // non-maskable interrupt to CPU
    ESC_LC_SCRAP      = 2,  // tell life-cycle controller to scrap
    ESC_RESET_LC      = 3,  // assert lifecycle reset domain
    ESC_RESET_SYS     = 4,  // assert system reset
    ESC_RESET_CHIP    = 5   // full chip reset
  } esc_action_e;

  // Source IP raises an alert
  typedef struct {
    string         source_name;     // e.g. "uart0", "otbn", "lc_ctrl"
    int            alert_id;        // global alert id
    esc_class_e    target_class;    // which escalation class this alert belongs to
    longint unsigned timestamp_ns;
  } AlertEvent_s;

  // Ping protocol: handler periodically pings each source to verify liveness
  typedef struct {
    string  source_name;
    int     alert_id;
    bit     ping_response;          // 1 = source replied; 0 = ping timeout
  } AlertPing_s;

  // The alert_handler publishes these as the FSM progresses through phases
  typedef struct {
    esc_class_e    klass;
    esc_phase_e    phase;
    esc_state_e    state;
    longint unsigned timestamp_ns;
    int            triggering_alert_id;   // -1 if not directly alert-triggered
  } EscPhaseChange_s;

  // Each phase fires an action (or none); subscribers act on these
  typedef struct {
    esc_class_e    klass;
    esc_phase_e    phase;
    esc_action_e   action;
    longint unsigned timestamp_ns;
  } EscAction_s;

  // Action handlers report back what happened, so the scoreboard can verify
  // the escalation chain ran end-to-end correctly
  typedef struct {
    esc_action_e   action;
    string         handler_name;
    bit            success;
    string         detail;
  } EscActionResult_s;

endpackage
