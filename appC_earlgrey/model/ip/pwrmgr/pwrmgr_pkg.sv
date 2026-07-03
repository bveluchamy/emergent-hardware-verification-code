// pwrmgr_pkg.sv  --  Earlgrey power manager messages.
//
// pwrmgr_aon orchestrates power transitions. It is a state machine in
// the always-on domain that talks to clkmgr (gate clocks during sleep)
// and rstmgr (assert/release reset domains).

package pwrmgr_pkg;
  import earlgrey_memory_map_pkg::*;

  // Wakeup sources (subset of Earlgrey's full wakeup vector)
  typedef enum int {
    PWR_WKUP_AON_TIMER  = 0,
    PWR_WKUP_USBDEV     = 1,
    PWR_WKUP_SYSRST     = 2,
    PWR_WKUP_PINMUX     = 3,
    PWR_WKUP_SENSOR     = 4,
    PWR_WKUP_ADC        = 5
  } pwr_wkup_src_e;

  // Software-issued power request: low-power entry
  typedef struct {
    bit             low_power_hint;     // SW asks to enter low-power
    bit             usb_clk_en_lp;       // keep USB clock during low-power
    bit             main_pd_n;          // 0 = power-down main rail
    longint unsigned timestamp_ns;
  } PwrLowPowerReq_s;

  // Wakeup event from a wakeup source
  typedef struct {
    pwr_wkup_src_e  source;
    longint unsigned timestamp_ns;
  } PwrWakeupEvent_s;

  // pwrmgr broadcasts its current state on every transition
  typedef struct {
    eg_pwr_state_e  prev_state;
    eg_pwr_state_e  next_state;
    longint unsigned timestamp_ns;
  } PwrStateTransition_s;

endpackage
