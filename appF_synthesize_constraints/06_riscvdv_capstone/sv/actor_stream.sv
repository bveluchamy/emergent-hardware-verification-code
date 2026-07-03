// 06_riscvdv_capstone slice 8: the SAME authored actor, TWO renderings. stream_gen.sv (slice 7) is the FABRIC
// rendering of the stream actor -- a synthesized clocked FSM. Here is the SIMULATION rendering of the
// *same* actor, written against the book's actor_pkg (Chapter 6) as an `Actor` subclass. The point:
// one authored definition, rendered per substrate (SV class for sim / RTL gates for the emulator)
// with NO user rewrite -- and the two renderings are BIT-IDENTICAL (validated in tb_actor_stream.sv).
`timescale 1ns/1ns
package actor_stream_pkg;
  import actor_pkg::*;

  typedef struct packed { logic [31:0] bits; } Instr_s;   // an emitted-instruction envelope

  // the SAME selection the RTL `rsel` implements: idx-th register NOT in `excluded`, clamped.
  function automatic logic [4:0] reg_select(logic [31:0] excluded, logic [4:0] idx);
    logic [5:0] c; logic done; logic [4:0] r_out;
    c = 6'd0; done = 1'b0; r_out = 5'd0;
    for (int r=0;r<32;r++) if(!excluded[r]) begin
      if(!done)           r_out = r[4:0];
      if(c=={1'b0,idx})   done  = 1'b1;
      c = c + 6'd1;
    end
    return r_out;
  endfunction

  // the SAME R-type op table as stream_gen.
  function automatic logic [9:0] op_funct(logic [3:0] sel);  // {funct7[6:0], funct3[2:0]}
    case (sel)
      4'd0:return{7'h00,3'h0}; 4'd1:return{7'h20,3'h0}; 4'd2:return{7'h00,3'h1}; 4'd3:return{7'h00,3'h2};
      4'd4:return{7'h00,3'h3}; 4'd5:return{7'h00,3'h4}; 4'd6:return{7'h00,3'h5}; 4'd7:return{7'h20,3'h5};
      4'd8:return{7'h00,3'h6}; default:return{7'h00,3'h7};
    endcase
  endfunction

  // the stream actor, SIM rendering. Its `live` member is the SAME cross-instruction state the
  // fabric rendering holds in 32 flip-flops; step() is the SAME per-cycle behavior.
  class StreamActor extends Actor;
    logic [31:0] live, reserved;
    function new(string name="StreamActor", logic [31:0] rsv=32'h1F, logic [31:0] init=32'h400);
      super.new(name); reserved = rsv; live = init;
    endfunction
    // one instruction: draw operands (rd non-reserved, rs1/rs2 from live), assemble, grow live.
    function automatic logic [31:0] step(logic [4:0] s_rd, s_rs1, s_rs2, logic [3:0] s_op);
      logic [4:0] rd, rs1, rs2; logic [6:0] f7; logic [2:0] f3; logic [31:0] instr;
      rd  = reg_select(reserved, s_rd);
      rs1 = reg_select(~live,   s_rs1);
      rs2 = reg_select(~live,   s_rs2);
      {f7, f3} = op_funct(s_op);
      instr = {f7, rs2, rs1, f3, rd, 7'b0110011};
      live = live | (32'd1 << rd);                    // same state update as the RTL always_ff
      return instr;
    endfunction
  endclass
endpackage
