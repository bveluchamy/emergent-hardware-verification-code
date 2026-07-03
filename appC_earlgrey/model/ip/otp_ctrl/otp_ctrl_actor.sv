// otp_ctrl_actor.sv  --  Earlgrey OTP controller (one-time programmable fuses).

import actor_pkg::*;
import otp_ctrl_pkg::*;
import reset_pkg::*;

class OtpCtrlActor extends Actor;
  logic [31:0]    fuses [otp_part_e][logic [31:0]];

  // Sideband seeds that get distributed to keymgr/lc_ctrl/rom_ctrl
  logic [255:0]   creator_root_seed;
  logic [255:0]   owner_seed;
  logic [255:0]   rom_hash;
  int             lc_state;

  function new(string name = "otp_ctrl");
    super.new(name);
  endfunction

  function void preload_seed(otp_part_e part, logic [31:0] addr, logic [31:0] data);
    fuses[part][addr] = data;
  endfunction

  function void set_seeds(logic [255:0] creator, logic [255:0] owner,
                          logic [255:0] rom_h,   int lc_st);
    creator_root_seed = creator;
    owner_seed        = owner;
    rom_hash          = rom_h;
    lc_state          = lc_st;
  endfunction

  // On reset deassertion, OTP "boots" -- publishes its initial state to
  // every consumer (keymgr, rom_ctrl, lc_ctrl).
  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(ResetEvent_s): begin
        ResetEvent_s r = Msg#(ResetEvent_s)::unwrap(msg);
        if (!r.asserted) publish_init_done();
      end
      $typename(OtpCmd_s): begin
        OtpCmd_s   cmd = Msg#(OtpCmd_s)::unwrap(msg);
        OtpRsp_s   rsp;
        rsp.partition = cmd.partition;
        rsp.addr      = cmd.addr;
        rsp.error     = 1'b0;
        if (cmd.write) begin
          // OTP is one-time-programmable: only write if currently zero
          if (fuses[cmd.partition].exists(cmd.addr) &&
              fuses[cmd.partition][cmd.addr] != 0) begin
            rsp.error = 1'b1;
          end else begin
            fuses[cmd.partition][cmd.addr] = cmd.data;
          end
          rsp.data = fuses[cmd.partition][cmd.addr];
        end else begin
          rsp.data = fuses[cmd.partition].exists(cmd.addr)
                     ? fuses[cmd.partition][cmd.addr] : '0;
        end
        `PUBLISH(rsp);
      end
    endcase
  endtask

  task publish_init_done();
    OtpInitDone_s ev;
    #200;     // simulate OTP read latency
    ev.creator_root_seed             = creator_root_seed;
    ev.creator_diversification_key   = creator_root_seed ^ 256'hAA55_AA55_AA55_AA55_AA55_AA55_AA55_AA55_AA55_AA55_AA55_AA55_AA55_AA55_AA55_AA55;
    ev.owner_seed                    = owner_seed;
    ev.rom_hash_digest               = rom_hash;
    ev.lc_state                      = lc_state;
    ev.timestamp_ns                  = $time;
    `PUBLISH(ev);
  endtask
endclass
