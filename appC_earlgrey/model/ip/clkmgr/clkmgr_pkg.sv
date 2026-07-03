// clkmgr_pkg.sv  --  Earlgrey clock manager messages.
package clkmgr_pkg;

  // pwrmgr -> clkmgr: gate or un-gate clock domains
  typedef struct {
    bit              io_clk_enable;
    bit              usb_clk_enable;
    bit              main_clk_enable;
    longint unsigned timestamp_ns;
  } ClkGateReq_s;

  // clkmgr -> world: clock state changed (every gate change)
  typedef struct {
    string           clock_name;     // "io", "usb", "main", "aon", "div2", "div4"
    bit              enabled;
    longint unsigned timestamp_ns;
  } ClkStateChange_s;

  // SW-issued request to gate a hint-able clock (the "transactional" clocks)
  typedef struct {
    string           clock_name;     // "main_aes", "main_kmac", "main_otbn", "main_hmac"
    bit              hint_enable;
    longint unsigned timestamp_ns;
  } ClkHintReq_s;

  // Measurement-control request (SW-driven clock-frequency measurement)
  typedef struct {
    string           target_clock;
    bit              enable;
    int              expected_min;
    int              expected_max;
  } ClkMeasReq_s;

endpackage
