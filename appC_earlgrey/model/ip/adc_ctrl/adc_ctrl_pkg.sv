// adc_ctrl_pkg.sv  --  Earlgrey ADC controller (in AON domain).
package adc_ctrl_pkg;

  parameter int unsigned EG_ADC_NUM_CHAN = 2;

  typedef enum logic [1:0] {
    ADC_MODE_NORMAL    = 0,
    ADC_MODE_LOW_POWER = 1,
    ADC_MODE_DEBUG     = 2
  } adc_mode_e;

  typedef struct {
    adc_mode_e          mode;
    bit                 enable [EG_ADC_NUM_CHAN];
    int                 threshold_high [EG_ADC_NUM_CHAN];
    int                 threshold_low  [EG_ADC_NUM_CHAN];
    longint unsigned    timestamp_ns;
  } AdcConfig_s;

  // Test stimulus: external world drives an analog value on a channel
  typedef struct {
    int                 channel;
    int                 sample_value;     // 0..1023 (10-bit ADC)
    longint unsigned    timestamp_ns;
  } AdcAnalogSample_s;

  // ADC publishes one sample event per filtered sample
  typedef struct {
    int                 channel;
    int                 sample_value;
    bit                 over_high;
    bit                 under_low;
    longint unsigned    timestamp_ns;
  } AdcSampleEvent_s;

  // Combined "wakeup" event: when a channel crosses both filters in a
  // configured pattern, ADC raises a wakeup to pwrmgr.
  typedef struct {
    int                 trigger_channel;
    longint unsigned    timestamp_ns;
  } AdcWakeup_s;

endpackage
