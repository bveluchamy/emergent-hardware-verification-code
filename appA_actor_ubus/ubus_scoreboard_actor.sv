// UbusScoreboardActor — mirrors ubus_example_scoreboard.sv.
// Receives UbusMonPkt_s from the bus monitor.
// Maintains a per-address shadow memory and checks READ data against it.

import actor_pkg::*;
import ubus_pkg::*;

class UbusScoreboardActor extends Actor;
  logic [7:0] shadow_mem[logic[15:0]];
  int  checks_passed = 0;
  int  checks_failed = 0;
  bit  sbd_error     = 0;

  function new(string name="ScoreboardActor");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(UbusMonPkt_s)) begin
      UbusMonPkt_s pkt = Msg#(UbusMonPkt_s)::unwrap(msg);

      case (pkt.dir)
        WRITE: begin
          shadow_mem[pkt.addr] = pkt.data;
          $display("[%0t] Scoreboard: Logged WRITE [0x%04h]=0x%02h",
                   $time, pkt.addr, pkt.data);
        end
        READ: begin
          if (shadow_mem.exists(pkt.addr)) begin
            if (shadow_mem[pkt.addr] === pkt.data) begin
              $display("[%0t] Scoreboard: READ PASS [0x%04h] exp=0x%02h got=0x%02h",
                       $time, pkt.addr, shadow_mem[pkt.addr], pkt.data);
              checks_passed++;
            end else begin
              $error("[%0t] Scoreboard: READ FAIL [0x%04h] exp=0x%02h got=0x%02h",
                     $time, pkt.addr, shadow_mem[pkt.addr], pkt.data);
              checks_failed++;
              sbd_error = 1;
            end
          end else begin
            $display("[%0t] Scoreboard: READ at 0x%04h (no prior write — data=0x%02h)",
                     $time, pkt.addr, pkt.data);
          end
        end
        default: ;
      endcase
    end
  endtask

  function void report();
    $display("========================================");
    $display("Scoreboard Report: PASS=%0d  FAIL=%0d",
             checks_passed, checks_failed);
    if (sbd_error)
      $display("** TEST FAILED **");
    else
      $display("** TEST PASSED **");
    $display("========================================");
  endfunction

endclass
