// uart_pkg.sv
//
// UART pin-level message contracts. Mirrors OpenTitan's UART feature set
// (tx/rx FIFOs, parity, baud rate, line break detection) but with the
// behavior/data split: this file only declares the structs.

package uart_pkg;

  typedef enum logic [1:0] {
    PARITY_NONE = 0,
    PARITY_ODD  = 1,
    PARITY_EVEN = 2
  } uart_parity_e;

  typedef enum logic [0:0] {
    UART_TX = 0,
    UART_RX = 1
  } uart_dir_e;

  typedef struct {
    int            baud_rate;       // bits per second
    uart_parity_e  parity;
    bit            two_stop_bits;
  } UartConfig_s;

  // One serial frame (after physical de/serialization)
  typedef struct {
    longint unsigned  id;
    uart_dir_e        dir;
    logic [7:0]       data;
    bit               parity_error;
    bit               frame_error;
    longint unsigned  timestamp_ns;
  } UartItem_s;

  // The OpenTitan UART has 8 interrupt sources; we model the most common
  typedef enum int {
    UART_INTR_TX_WATERMARK  = 0,
    UART_INTR_RX_WATERMARK  = 1,
    UART_INTR_TX_DONE       = 2,
    UART_INTR_RX_OVERFLOW   = 3,
    UART_INTR_RX_FRAME_ERR  = 4,
    UART_INTR_RX_BREAK_ERR  = 5,
    UART_INTR_RX_TIMEOUT    = 6,
    UART_INTR_RX_PARITY_ERR = 7
  } uart_intr_e;

  // UART register addresses (subset of OpenTitan's CSR layout)
  parameter logic [31:0] UART_INTR_STATE_ADDR = 32'h0000_0000;
  parameter logic [31:0] UART_INTR_ENABLE_ADDR= 32'h0000_0004;
  parameter logic [31:0] UART_CTRL_ADDR       = 32'h0000_0010;
  parameter logic [31:0] UART_STATUS_ADDR     = 32'h0000_0014;
  parameter logic [31:0] UART_RDATA_ADDR      = 32'h0000_0018;
  parameter logic [31:0] UART_WDATA_ADDR      = 32'h0000_001C;
  parameter logic [31:0] UART_FIFO_CTRL_ADDR  = 32'h0000_0020;
  parameter logic [31:0] UART_FIFO_STATUS_ADDR= 32'h0000_0024;

endpackage
