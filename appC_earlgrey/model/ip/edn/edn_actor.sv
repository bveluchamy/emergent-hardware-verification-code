// edn_actor.sv  --  Entropy Distribution Network endpoint.
//
// Each EDN instance subscribes to EdnReq_s from its consumers (AES /
// KMAC / OTBN / keymgr) and forwards a CsrngCmd_s GENERATE request to
// CSRNG. When CSRNG responds, it repackages the random words into an
// EdnRsp_s for the requesting consumer.

import actor_pkg::*;
import edn_pkg::*;
import csrng_pkg::*;

class EdnActor extends Actor;
  int  edn_id;            // 0 or 1
  int  fifo_words = 16;   // stored output words per refresh

  // Pre-loaded buffer of random words, refreshed by CSRNG
  logic [31:0] buffer [$];

  // Pending consumers waiting for output
  int  pending_consumers [$];

  function new(int edn_id, string name = "edn");
    super.new(name);
    this.edn_id = edn_id;
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(EdnReq_s): begin
        EdnReq_s r = Msg#(EdnReq_s)::unwrap(msg);
        serve_or_queue(r);
      end
      $typename(CsrngRsp_s): begin
        CsrngRsp_s rsp = Msg#(CsrngRsp_s)::unwrap(msg);
        if (rsp.instance_id != edn_id) return;     // not ours
        if (rsp.op == CSRNG_GENERATE) refill(rsp);
      end
    endcase
  endtask

  task serve_or_queue(EdnReq_s req);
    if (buffer.size() >= 4) begin
      EdnRsp_s out;
      out.consumer_id   = req.consumer_id;
      out.bus_data      = new[4];
      for (int i = 0; i < 4; i++) out.bus_data[i] = buffer.pop_front();
      out.timestamp_ns  = $time;
      `PUBLISH(out);
    end else begin
      // Buffer empty -- queue and trigger a CSRNG GENERATE
      pending_consumers.push_back(req.consumer_id);
      request_refill();
    end
  endtask

  task request_refill();
    CsrngCmd_s cmd;
    cmd.instance_id    = edn_id;
    cmd.op             = CSRNG_GENERATE;
    cmd.gen_len_words  = fifo_words / 4;     // CSRNG returns 128-bit words
    cmd.timestamp_ns   = $time;
    `PUBLISH(cmd);
  endtask

  function void refill(CsrngRsp_s rsp);
    foreach (rsp.rnd_word[i]) begin
      buffer.push_back(rsp.rnd_word[i][31:0]);
      buffer.push_back(rsp.rnd_word[i][63:32]);
      buffer.push_back(rsp.rnd_word[i][95:64]);
      buffer.push_back(rsp.rnd_word[i][127:96]);
    end
    // Drain queued consumers
    while (pending_consumers.size() > 0 && buffer.size() >= 4) begin
      int cid = pending_consumers.pop_front();
      EdnRsp_s out;
      out.consumer_id   = cid;
      out.bus_data      = new[4];
      for (int i = 0; i < 4; i++) out.bus_data[i] = buffer.pop_front();
      out.timestamp_ns  = $time;
      `PUBLISH(out);
    end
  endfunction
endclass
