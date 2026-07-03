// pwm_actor.sv  --  Earlgrey PWM channel generator.
//
// Each channel is independent. Configuration message stores period and
// duty; a background thread per channel ticks on a 1MHz pwm_clk and
// publishes PwmPulse_s on each edge.

import actor_pkg::*;
import pwm_pkg::*;

class PwmActor extends Actor;
  PwmConfig_s   ch_cfg [int];
  bit           ch_running [int];

  function new(string name = "pwm_aon");
    super.new(name);
  endfunction

  virtual task run();
    fork
      forever begin
        MsgBase msg;
        mbox.get(msg);
        act(msg);
      end
      // One generator thread per channel; spawned lazily as channels
      // get configured.
      forever begin
        #1000;     // 1us tick, 1 MHz pwm_clk equivalent
        foreach (ch_cfg[ch]) if (ch_cfg[ch].enable) tick(ch);
      end
    join
  endtask

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(PwmConfig_s)) begin
      PwmConfig_s c = Msg#(PwmConfig_s)::unwrap(msg);
      ch_cfg[c.channel] = c;
    end
  endtask

  // Per-tick state -- which cycle of the period is each channel in?
  int  ch_phase [int];

  task tick(int ch);
    PwmConfig_s c = ch_cfg[ch];
    bit         level;
    bit         prev_level;
    if (c.period_cycles == 0) return;
    prev_level     = (ch_phase[ch] < c.duty_cycles) ^ c.invert;
    ch_phase[ch]   = (ch_phase[ch] + 1) % c.period_cycles;
    level          = (ch_phase[ch] < c.duty_cycles) ^ c.invert;
    if (level !== prev_level) begin
      PwmPulse_s p;
      p.channel       = ch;
      p.value         = level;
      p.timestamp_ns  = $time;
      `PUBLISH(p);
    end
  endtask
endclass
