// alert_source_actor.sv
//
// Models an alert source on an IP. In silicon, every IP that can detect a
// fault has an alert sender block that drives the alert lines to the
// alert_handler. Test stimulus may want to inject fake alerts for
// verification (escalation testing, ping-protocol testing, recovery
// testing).
//
// As an actor, an alert source is essentially a "publish AlertEvent_s on
// command" function -- nothing more. The hard logic (timer, escalation
// FSM) lives in the alert_handler actor.

import actor_pkg::*;
import alert_pkg::*;

class AlertSourceActor extends Actor;
  string         source_name;
  int            alert_id;
  esc_class_e    target_class;

  function new(string source_name, int alert_id, esc_class_e target_class,
               string name = "AlertSourceActor");
    super.new(name);
    this.source_name  = source_name;
    this.alert_id     = alert_id;
    this.target_class = target_class;
  endfunction

  // Test code calls this to inject a fake alert
  function void trigger();
    AlertEvent_s ev;
    ev.source_name   = source_name;
    ev.alert_id      = alert_id;
    ev.target_class  = target_class;
    ev.timestamp_ns  = $time;
    `PUBLISH(ev);
  endfunction

  // Source can also receive ping requests; we just ack them. In real
  // silicon the source's ping responder is more careful.
  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(AlertPing_s)) begin
      AlertPing_s p = Msg#(AlertPing_s)::unwrap(msg);
      if (p.source_name == source_name) begin
        AlertPing_s ack;
        ack.source_name   = source_name;
        ack.alert_id      = alert_id;
        ack.ping_response = 1'b1;
        `PUBLISH(ack);
      end
    end
  endtask
endclass
