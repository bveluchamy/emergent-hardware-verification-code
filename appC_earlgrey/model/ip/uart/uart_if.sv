// uart_if.sv  -- pin-level interface for the UART under test.
interface uart_if(input logic clk_i, input logic rst_ni);
  logic tx;     // DUT -> wire
  logic rx;     // wire -> DUT
endinterface
