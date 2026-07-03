// pinmux_pkg.sv  --  Earlgrey pin multiplexer / pad control.
//
// Routes IP-internal MIO/DIO signals to physical pads. SW configures a
// table mapping each pad to one IP signal. This is mostly a configuration
// IP -- once set, it routes signals statically.

package pinmux_pkg;

  parameter int unsigned EG_NUM_MIO_PADS = 47;     // matches Earlgrey
  parameter int unsigned EG_NUM_DIO_PADS = 16;

  typedef enum int {
    PINMUX_OUT_DIRECTION = 0,
    PINMUX_IN_DIRECTION  = 1
  } pinmux_direction_e;

  // Configure one MIO pad: which IP signal drives it (out) or receives it (in)
  typedef struct {
    pinmux_direction_e  direction;
    int                 pad_index;       // 0..EG_NUM_MIO_PADS-1
    int                 signal_id;       // arbitrary IP-side signal id
    longint unsigned    timestamp_ns;
  } PinmuxCfg_s;

  // Per-pad attribute change (pull / drive / OD / input-enable / etc.)
  typedef struct {
    int                 pad_index;
    bit                 input_enable;
    bit                 output_enable;
    bit                 pull_up;
    bit                 pull_down;
    bit                 open_drain;
    bit                 schmitt_trigger;
    longint unsigned    timestamp_ns;
  } PinmuxPadAttr_s;

endpackage
