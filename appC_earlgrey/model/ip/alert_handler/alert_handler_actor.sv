// alert_handler_actor.sv
//
// The OpenTitan alert_handler as a Finite State Machine actor.
//
// In silicon, the alert_handler runs four parallel "escalation classes"
// (A/B/C/D), each with a 4-phase timer. When an alert fires for a class:
//   * State transitions IDLE -> TIMING
//   * Phase 0 fires its configured action immediately
//   * Phase 1/2/3 fire on configurable delays after entry
//   * State returns to IDLE (or terminal) after Phase 3
//
// In UVM this is modeled as a complex scoreboard reconstruction problem.
// Here it is one FSM actor per class, plus per-class phase timers, plus
// EscAction_s publishes on phase entry. Subscribers (NmiActor,
// ResetSupervisor, LcCtrlActor, scoreboard) are `WIRE'd for what they care
// about and react.
//
// Crucially, the four classes are *separate actors* -- they cannot
// interfere with each other and each can be stopped/restarted/glitched
// independently. UVM's class-hierarchy approach forces them into one big
// component.

import actor_pkg::*;
import alert_pkg::*;
import reset_pkg::*;

// One escalation-class FSM. Instantiated four times.
class EscClassFsmActor extends Actor;
  esc_class_e               klass;
  esc_state_e               state;
  esc_phase_e               current_phase;

  // Per-phase delays in ns
  longint unsigned          phase_delay_ns [4] = '{0, 200, 200, 200};
  // Per-phase action (configured by the test or env)
  esc_action_e              phase_action   [4] = '{ESC_NMI, ESC_LC_SCRAP, ESC_RESET_SYS, ESC_RESET_CHIP};

  // Last alert that triggered this class
  int                       triggering_alert_id;

  function new(esc_class_e klass, string name = "EscClassFsmActor");
    super.new(name);
    this.klass         = klass;
    this.state         = STATE_IDLE;
    this.current_phase = PHASE_0;
    this.triggering_alert_id = -1;
  endfunction

  // Listens for AlertEvent_s targeting this class. When one arrives in
  // STATE_IDLE, kick off the escalation cascade.
  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(AlertEvent_s)) begin
      AlertEvent_s ev = Msg#(AlertEvent_s)::unwrap(msg);
      if (ev.target_class != klass) return;     // other class's problem
      if (state != STATE_IDLE) return;          // already escalating
      triggering_alert_id = ev.alert_id;
      run_escalation();
    end else if (msg.getTypeName() == $typename(ResetEvent_s)) begin
      ResetEvent_s r = Msg#(ResetEvent_s)::unwrap(msg);
      if (r.asserted) begin
        state = STATE_IDLE;
        current_phase = PHASE_0;
      end
    end
  endtask

  task run_escalation();
    // Phase 0..3 cascade
    transition(STATE_TIMING, PHASE_0);
    fire_action(PHASE_0);
    if (phase_delay_ns[0] > 0) #(phase_delay_ns[0] * 1ns);

    transition(STATE_TIMING, PHASE_1);
    fire_action(PHASE_1);
    if (phase_delay_ns[1] > 0) #(phase_delay_ns[1] * 1ns);

    transition(STATE_TIMING, PHASE_2);
    fire_action(PHASE_2);
    if (phase_delay_ns[2] > 0) #(phase_delay_ns[2] * 1ns);

    transition(STATE_TIMING, PHASE_3);
    fire_action(PHASE_3);
    if (phase_delay_ns[3] > 0) #(phase_delay_ns[3] * 1ns);

    transition(STATE_TERMINAL, PHASE_3);
  endtask

  function void transition(esc_state_e next_state, esc_phase_e next_phase);
    EscPhaseChange_s ev;
    state         = next_state;
    current_phase = next_phase;
    ev.klass               = klass;
    ev.phase               = next_phase;
    ev.state               = next_state;
    ev.timestamp_ns        = $time;
    ev.triggering_alert_id = triggering_alert_id;
    `PUBLISH(ev);
  endfunction

  function void fire_action(esc_phase_e phase);
    EscAction_s a;
    a.klass         = klass;
    a.phase         = phase;
    a.action        = phase_action[phase];
    a.timestamp_ns  = $time;
    `PUBLISH(a);
  endfunction
endclass

// Top-level alert handler: holds the four FSMs and forwards alerts.
// Itself is also an actor so test infrastructure can talk to it as a
// single entity if it wants.
class AlertHandlerActor extends Actor;
  EscClassFsmActor  classes [4];

  function new(string name = "AlertHandlerActor");
    super.new(name);
    classes[0] = new(CLASS_A, "alert.classA");
    classes[1] = new(CLASS_B, "alert.classB");
    classes[2] = new(CLASS_C, "alert.classC");
    classes[3] = new(CLASS_D, "alert.classD");
  endfunction

  // The test wires AlertSourceActor -> AlertHandlerActor, so we receive
  // each AlertEvent_s here and broadcast to all four class FSMs. Each
  // FSM checks target_class and ignores or consumes accordingly.
  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(AlertEvent_s)) begin
      AlertEvent_s ev = Msg#(AlertEvent_s)::unwrap(msg);
      // Broadcast to all four FSMs (each filters on target_class)
      foreach (classes[i]) begin
        `PUBLISH_TO(classes[i], ev);
      end
    end
  endtask
endclass
