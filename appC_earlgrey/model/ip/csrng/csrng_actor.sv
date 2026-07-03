// csrng_actor.sv
//
// CSRNG = Cryptographically Secure RNG. Subscribes to EntropySeed_s
// from entropy_src; services CsrngCmd_s requests from EDN0/EDN1 (and SW).
import actor_pkg::*;
import csrng_pkg::*;
import entropy_src_pkg::*;

class CsrngActor extends Actor;
  // Internal state per instance: seed + counter (DRBG state)
  logic [383:0]    drbg_seed [int];
  int              drbg_ctr  [int];
  // Latest entropy seed buffered until we need one
  logic [383:0]    pending_seed;
  bit              pending_valid;
  int              ops_done;

  function new(string name = "csrng");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(EntropySeed_s): begin
        EntropySeed_s e = Msg#(EntropySeed_s)::unwrap(msg);
        pending_seed   = e.seed;
        pending_valid  = 1'b1;
      end
      $typename(CsrngCmd_s): begin
        CsrngCmd_s cmd = Msg#(CsrngCmd_s)::unwrap(msg);
        execute(cmd);
      end
    endcase
  endtask

  task execute(CsrngCmd_s cmd);
    CsrngRsp_s rsp;
    rsp.instance_id  = cmd.instance_id;
    rsp.op           = cmd.op;
    rsp.error        = 1'b0;

    case (cmd.op)
      CSRNG_INSTANTIATE: begin
        if (!pending_valid) rsp.error = 1'b1;
        else begin
          drbg_seed[cmd.instance_id] = pending_seed;
          drbg_ctr[cmd.instance_id]  = 0;
          pending_valid = 1'b0;
        end
      end
      CSRNG_RESEED: begin
        if (!pending_valid) rsp.error = 1'b1;
        else begin
          drbg_seed[cmd.instance_id] ^= pending_seed;
          drbg_ctr[cmd.instance_id]   = 0;
          pending_valid = 1'b0;
        end
      end
      CSRNG_GENERATE: begin
        rsp.rnd_word = new[cmd.gen_len_words];
        for (int i = 0; i < cmd.gen_len_words; i++) begin
          // DRBG output: simple counter-mode toy AES-CTR-like construction
          drbg_ctr[cmd.instance_id]++;
          rsp.rnd_word[i] = drbg_seed[cmd.instance_id][127:0] ^
                            {96'b0, drbg_ctr[cmd.instance_id][31:0]};
        end
      end
      CSRNG_UNINSTANTIATE: begin
        drbg_seed.delete(cmd.instance_id);
        drbg_ctr.delete(cmd.instance_id);
      end
      default: ;
    endcase

    rsp.timestamp_ns = $time;
    ops_done++;
    `PUBLISH(rsp);
  endtask
endclass
