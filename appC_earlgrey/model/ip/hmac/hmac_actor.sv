import actor_pkg::*;
import hmac_pkg::*;

class HmacActor extends Actor;
  int  ops_done;

  function new(string name = "hmac");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    if (msg.getTypeName() == $typename(HmacCmd_s)) begin
      HmacCmd_s cmd = Msg#(HmacCmd_s)::unwrap(msg);
      HmacRsp_s rsp;
      logic [511:0] h = '0;

      ops_done++;
      #(300 + cmd.msg.size() * 4);

      // Behavioral hash (not cryptographically real)
      foreach (cmd.msg[i]) h[(i * 8) % 512 +: 8] ^= cmd.msg[i];
      if (cmd.hmac_en) h ^= cmd.key[511:0];

      rsp.digest        = h;
      rsp.timestamp_ns  = $time;
      `PUBLISH(rsp);
    end
  endtask
endclass
