// adc_ctrl_actor.sv  --  Earlgrey ADC controller (AON-domain).
import actor_pkg::*;
import adc_ctrl_pkg::*;

class AdcCtrlActor extends Actor;
  AdcConfig_s   cfg;
  bit           configured;
  // Last sample per channel (for windowed-filter logic, simplified)
  int           last_sample [EG_ADC_NUM_CHAN];
  bit           saw_high    [EG_ADC_NUM_CHAN];
  bit           saw_low     [EG_ADC_NUM_CHAN];

  function new(string name = "adc_ctrl_aon");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(AdcConfig_s): begin
        cfg         = Msg#(AdcConfig_s)::unwrap(msg);
        configured  = 1'b1;
      end
      $typename(AdcAnalogSample_s): begin
        AdcAnalogSample_s s = Msg#(AdcAnalogSample_s)::unwrap(msg);
        process_sample(s);
      end
    endcase
  endtask

  task process_sample(AdcAnalogSample_s s);
    AdcSampleEvent_s ev;
    if (!configured || !cfg.enable[s.channel]) return;
    last_sample[s.channel]   = s.sample_value;

    ev.channel               = s.channel;
    ev.sample_value          = s.sample_value;
    ev.over_high             = (s.sample_value > cfg.threshold_high[s.channel]);
    ev.under_low             = (s.sample_value < cfg.threshold_low [s.channel]);
    ev.timestamp_ns          = $time;
    `PUBLISH(ev);

    if (ev.over_high) saw_high[s.channel] = 1'b1;
    if (ev.under_low) saw_low [s.channel] = 1'b1;

    // Both crossings observed -> wakeup
    if (saw_high[s.channel] && saw_low[s.channel]) begin
      AdcWakeup_s w;
      w.trigger_channel  = s.channel;
      w.timestamp_ns     = $time;
      `PUBLISH(w);
      saw_high[s.channel] = 1'b0;
      saw_low [s.channel] = 1'b0;
    end
  endtask
endclass
