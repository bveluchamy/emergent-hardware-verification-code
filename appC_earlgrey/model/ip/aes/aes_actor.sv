// aes_actor.sv  --  Earlgrey AES (behavioral; not cryptographically real).
import actor_pkg::*;
import aes_pkg::*;

class AesActor extends Actor;
  int  ops_done;

  function new(string name = "aes");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(AesCmd_s)) begin
      AesCmd_s cmd = Msg#(AesCmd_s)::unwrap(msg);
      AesRsp_s rsp;
      ops_done++;
      // Simulate AES round latency (real Earlgrey AES takes ~12 cycles per block)
      #120;
      // Toy XOR for demo (NOT cryptographically real)
      rsp.op            = cmd.op;
      rsp.output_block  = cmd.plaintext ^ cmd.key[127:0] ^ cmd.iv;
      rsp.error         = 1'b0;
      rsp.timestamp_ns  = $time;
      `PUBLISH(rsp);
    end
  endtask
endclass
