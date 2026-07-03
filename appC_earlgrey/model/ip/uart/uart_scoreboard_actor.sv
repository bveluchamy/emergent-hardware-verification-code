// uart_scoreboard_actor.sv
//
// UART scoreboard. In OpenTitan UVM the equivalent is uart_scoreboard.sv
// (605 lines). This implementation handles the same checking discipline:
//   * TX-side stimulus is staged by the test thread (predicted bytes)
//   * The BFM's RX-side capture publishes the bytes actually observed
//     on the wire
//   * Scoreboard pairs predicted and observed and flags any mismatch
//
// Subscribers it consumes (via `WIRE from the env):
//   * UartItem_s     -- BFM-observed wire frames
//   * TlulMonPkt_s   -- bus-side register reads/writes that affect TX/RX
//                       FIFOs (so the scoreboard knows when the DUT
//                       enqueued or dequeued a byte)
//   * IrqMsg_s       -- predicted vs. observed interrupt firing
//
// Cross-stream verification IS the scoreboard's job. Every stream is just
// `WIRE'd in -- the actor framework doesn't need an analysis_imp_decl
// macro for each one.

import actor_pkg::*;
import uart_pkg::*;
import tlul_pkg::*;
import irq_pkg::*;

class UartScoreboardActor extends Actor;
  // Predicted (test-staged) tx bytes
  logic [7:0]   predicted_tx_q [$];
  // Observed bytes on the tx wire
  logic [7:0]   observed_tx_q [$];

  int           pass_count;
  int           fail_count;
  int           parity_errors_seen;
  int           frame_errors_seen;

  function new(string name = "UartScoreboardActor");
    super.new(name);
  endfunction

  function void predict_tx(logic [7:0] data);
    predicted_tx_q.push_back(data);
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(UartItem_s): begin
        UartItem_s item = Msg#(UartItem_s)::unwrap(msg);
        if (item.dir == UART_RX) begin
          // RX from the DUT's perspective = TX on the wire
          observed_tx_q.push_back(item.data);
          if (item.parity_error) parity_errors_seen++;
          if (item.frame_error)  frame_errors_seen++;
          check_match();
        end
      end
      $typename(TlulMonPkt_s): begin
        TlulMonPkt_s pkt = Msg#(TlulMonPkt_s)::unwrap(msg);
        // When test writes UART_WDATA register, that means the DUT will
        // enqueue this byte for TX on the wire eventually
        if (pkt.addr == UART_WDATA_ADDR &&
            (pkt.a_opcode == TL_PUT_FULL || pkt.a_opcode == TL_PUT_PARTIAL)) begin
          predict_tx(pkt.wdata[7:0]);
        end
      end
      $typename(IrqMsg_s): begin
        IrqMsg_s irq = Msg#(IrqMsg_s)::unwrap(msg);
        // Could verify that the IRQ corresponds to a state we predicted
        // (e.g. tx_done IRQ should follow a successful tx). Left as a
        // hook -- per-IRQ-vector predictions go here.
      end
    endcase
  endtask

  function void check_match();
    if (predicted_tx_q.size() == 0 || observed_tx_q.size() == 0) return;
    begin
      logic [7:0] pred = predicted_tx_q.pop_front();
      logic [7:0] obs  = observed_tx_q.pop_front();
      if (pred === obs) begin
        pass_count++;
      end else begin
        fail_count++;
        $error("UartScoreboard MISMATCH: predicted=%02h observed=%02h", pred, obs);
      end
    end
  endfunction

  function void report();
    $display("UartScoreboard: %0d pass / %0d fail / %0d parity-err / %0d frame-err",
             pass_count, fail_count, parity_errors_seen, frame_errors_seen);
  endfunction
endclass
