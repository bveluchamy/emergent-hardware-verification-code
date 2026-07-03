// entropy_src_actor.sv  --  consumes noise, runs health tests, emits seeds.
import actor_pkg::*;
import entropy_src_pkg::*;
import alert_pkg::*;

class EntropySrcActor extends Actor;
  // Accumulator for the next seed
  bit [383:0]    seed_buffer;
  int            bits_collected;
  int            seeds_emitted;
  int            health_failures;

  // Health-test thresholds (real entropy_src has many; we stub two)
  int            repcnt_max = 32;
  int            adaptp_max = 480;

  // Most-recent raw sample, for repetition-count test
  logic [3:0]    last_raw;
  int            repcnt_run;

  function new(string name = "entropy_src");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(EntropyNoiseSample_s)) begin
      EntropyNoiseSample_s s = Msg#(EntropyNoiseSample_s)::unwrap(msg);
      ingest(s.raw_bits);
    end
  endtask

  task ingest(logic [3:0] raw);
    // Repetition count test
    if (raw === last_raw) repcnt_run++;
    else                   repcnt_run = 1;
    if (repcnt_run > repcnt_max) report_health_fail("repcnt");
    last_raw = raw;

    // Accumulate
    seed_buffer = (seed_buffer << 4) | raw;
    bits_collected += 4;

    // Emit seed when we've gathered 384 bits
    if (bits_collected >= 384) begin
      EntropySeed_s ev;
      ev.seed             = seed_buffer;
      ev.fips_compliant   = (health_failures == 0);
      ev.timestamp_ns     = $time;
      `PUBLISH(ev);
      seeds_emitted++;
      bits_collected = 0;
      seed_buffer    = '0;
    end
  endtask

  function void report_health_fail(string test_name);
    EntropyHealthAlert_s a;
    AlertEvent_s         alert;
    health_failures++;
    a.test_name      = test_name;
    a.fail_count     = health_failures;
    a.timestamp_ns   = $time;
    `PUBLISH(a);
    if (health_failures > 8) begin
      // Persistent failure -> alert
      alert.source_name   = name;
      alert.alert_id      = 50;     // arbitrary entropy_src alert id
      alert.target_class  = CLASS_A;
      alert.timestamp_ns  = $time;
      `PUBLISH(alert);
    end
  endfunction
endclass
