// gpio_pkg.sv  --  Earlgrey GPIO controller messages.
package gpio_pkg;

  // SW writes / reads the GPIO output / input register
  typedef struct {
    logic [31:0]      data;
    logic [31:0]      mask;        // for masked write
    longint unsigned  timestamp_ns;
  } GpioSetCmd_s;

  // External world drives an input pin
  typedef struct {
    int               pin;
    logic             value;
    longint unsigned  timestamp_ns;
  } GpioInputChange_s;

  // GPIO publishes its current input/output snapshot on every change
  typedef struct {
    logic [31:0]      out_value;
    logic [31:0]      in_value;
    logic [31:0]      out_enable;
    longint unsigned  timestamp_ns;
  } GpioState_s;

  // Interrupt-on-change event (one per configured pin that toggled)
  typedef struct {
    int               pin;
    logic             new_value;
    longint unsigned  timestamp_ns;
  } GpioIntr_s;

endpackage
