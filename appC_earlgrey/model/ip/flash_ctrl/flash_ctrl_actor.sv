// flash_ctrl_actor.sv
//
// Earlgrey embedded flash. Behavioral model: two banks (data + info),
// each backed by an associative array. Address-scrambled in real silicon
// but transparent here. Read latency simulated as 5 ns/word; program as
// 20 ns/word; erase as 1 us/page.

import actor_pkg::*;
import flash_ctrl_pkg::*;
import irq_pkg::*;

class FlashCtrlActor extends Actor;
  // Backing store
  logic [31:0]   data_part [logic [31:0]];
  logic [31:0]   info_part [logic [31:0]];

  // Status
  FlashStatus_s  status;

  // Stats
  int            ops_read;
  int            ops_prog;
  int            ops_erase;

  function new(string name = "flash_ctrl");
    super.new(name);
    status.data_part_locked    = 1'b0;
    status.info_part_locked    = 1'b1;     // info partitions usually locked from SW
    status.creator_seed_valid  = 1'b1;
    status.owner_seed_valid    = 1'b1;
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(FlashCmd_s)) begin
      FlashCmd_s cmd = Msg#(FlashCmd_s)::unwrap(msg);
      execute(cmd);
    end
  endtask

  task execute(FlashCmd_s cmd);
    FlashRsp_s rsp;
    bit        ok = 1'b1;
    string     err;
    int        latency_ns;

    rsp.op           = cmd.op;
    rsp.addr         = cmd.addr;

    case (cmd.op)
      FLASH_OP_READ: begin
        ops_read++;
        if (cmd.partition == FLASH_PART_DATA) begin
          rsp.data = data_part.exists(cmd.addr) ? data_part[cmd.addr] : '0;
        end else begin
          rsp.data = info_part.exists(cmd.addr) ? info_part[cmd.addr] : '0;
        end
        latency_ns = 5;
      end
      FLASH_OP_PROG: begin
        ops_prog++;
        if (cmd.partition == FLASH_PART_DATA) begin
          if (status.data_part_locked) begin ok = 0; err = "data partition locked"; end
          else data_part[cmd.addr] = cmd.data;
        end else begin
          if (status.info_part_locked) begin ok = 0; err = "info partition locked"; end
          else info_part[cmd.addr] = cmd.data;
        end
        latency_ns = 20;
      end
      FLASH_OP_ERASE: begin
        ops_erase++;
        // Erase a 2KB page (512 words)
        if (cmd.partition == FLASH_PART_DATA) begin
          if (status.data_part_locked) begin ok = 0; err = "data partition locked"; end
          else for (int i = 0; i < 512; i++) data_part.delete(cmd.addr + i);
        end
        latency_ns = 1000;
      end
    endcase

    #(latency_ns);

    rsp.done          = 1'b1;
    rsp.error         = !ok;
    rsp.error_reason  = err;
    rsp.timestamp_ns  = $time;
    `PUBLISH(rsp);
  endtask

  function void load_image(logic [31:0] base, logic [31:0] words []);
    foreach (words[i]) data_part[base + i] = words[i];
  endfunction
endclass
