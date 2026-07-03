// pwm_pkg.sv  --  Earlgrey PWM channels.
package pwm_pkg;

  parameter int unsigned EG_NUM_PWM_CHANNELS = 6;

  typedef struct {
    int               channel;
    bit               enable;
    int               period_cycles;
    int               duty_cycles;       // 0 .. period_cycles
    bit               invert;
    longint unsigned  timestamp_ns;
  } PwmConfig_s;

  // PWM publishes pulse events on each rising and falling edge of each
  // active channel, so coverage / scoreboard actors can verify duty cycle.
  typedef struct {
    int               channel;
    logic             value;             // new pin value
    longint unsigned  timestamp_ns;
  } PwmPulse_s;

endpackage
