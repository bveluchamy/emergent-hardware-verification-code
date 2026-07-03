// kmac_actor.sv  --  KMAC (Keccak-MAC). Behavioral.
import actor_pkg::*;
import kmac_pkg::*;

class KmacActor extends Actor;
  int  ops_done;

  function new(string name = "kmac");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(KmacCmd_s)) begin
      KmacCmd_s cmd = Msg#(KmacCmd_s)::unwrap(msg);
      KmacRsp_s rsp;
      logic [511:0] h = '0;

      ops_done++;
      // KMAC latency scales with message length
      #(500 + cmd.msg.size() * 5);

      // Trivial behavioral hash: XOR-fold + key-mix (not cryptographic)
      foreach (cmd.msg[i]) h[(i * 8) % 512 +: 8] ^= cmd.msg[i];
      h ^= cmd.key;

      rsp.digest        = h;
      rsp.actual_len    = cmd.digest_len;
      rsp.error         = 1'b0;
      rsp.timestamp_ns  = $time;
      `PUBLISH(rsp);
    end
  endtask
endclass
