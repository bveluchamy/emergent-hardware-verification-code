// 06_riscvdv_capstone slice 7: THE INTEGRATION -- the per-slice samplers WIRED into a full instruction
// STREAM actor with CROSS-INSTRUCTION STATE. A clocked actor (actor == synthesizable FSM): each
// cycle it emits one R-type instruction, threading a LIVE register set across the stream so source
// registers are never read before they are written (riscv-dv's gpr-initialization discipline) --
// the thing a flat per-instruction generator cannot do and UVM needs a stateful sequencer for.

// idx-th register NOT in `excluded`, clamped (slices 1/5 reg_select_ex, reused as the wiring node).
module rsel (input logic [31:0] excluded, input logic [4:0] idx, output logic [4:0] reg_out);
  always_comb begin
    logic [5:0] c; logic done; reg_out=5'd0; c=6'd0; done=1'b0;
    for (int r=0;r<32;r++) if(!excluded[r]) begin
      if (!done)           reg_out = r[4:0];
      if (c == {1'b0,idx}) done = 1'b1;
      c = c + 6'd1;
    end
  end
endmodule

module stream_gen (
  input  logic        clk, rst,                    // rst loads the init (live) GPR set
  input  logic [31:0] reserved,                    // cfg.reserved_regs (incl ZERO)
  input  logic [31:0] init_live,                   // GPRs initialized before the stream starts
  input  logic [4:0]  seed_rd, seed_rs1, seed_rs2, // per-cycle operand seeds (the sampler draws)
  input  logic [3:0]  seed_op,                     // R-type op select
  output logic [31:0] instr,                       // assembled R-type instruction
  output logic [4:0]  rd, rs1, rs2,                // exposed for checking
  output logic [31:0] live);                       // the cross-instruction state (grows each cycle)

  // R-type op table (funct7, funct3) -- slice 1's op_table.
  logic [6:0] f7; logic [2:0] f3;
  always_comb begin
    case (seed_op[3:0])
      4'd0:{f7,f3}={7'h00,3'h0}; 4'd1:{f7,f3}={7'h20,3'h0}; // ADD, SUB
      4'd2:{f7,f3}={7'h00,3'h1}; 4'd3:{f7,f3}={7'h00,3'h2}; // SLL, SLT
      4'd4:{f7,f3}={7'h00,3'h3}; 4'd5:{f7,f3}={7'h00,3'h4}; // SLTU, XOR
      4'd6:{f7,f3}={7'h00,3'h5}; 4'd7:{f7,f3}={7'h20,3'h5}; // SRL, SRA
      4'd8:{f7,f3}={7'h00,3'h6}; default:{f7,f3}={7'h00,3'h7}; // OR, AND
    endcase
  end

  // WIRE the samplers: rd from non-reserved; rs1/rs2 from the LIVE set (= NOT ~live) -- cross-instr.
  rsel u_rd (.excluded(reserved),   .idx(seed_rd),  .reg_out(rd));
  rsel u_rs1(.excluded(~live),      .idx(seed_rs1), .reg_out(rs1));   // idx-th LIVE register
  rsel u_rs2(.excluded(~live),      .idx(seed_rs2), .reg_out(rs2));
  assign instr = {f7, rs2, rs1, f3, rd, 7'b0110011};                 // slice-4 R-type assembly

  // the actor's state: live GPR set. rd becomes live after it is written (sequential dependency).
  // synchronous reset loads the init GPR set (init_live is a runtime value, so a sync load avoids
  // the unsupported async-set+async-reset FF on ice40).
  always_ff @(posedge clk)
    if (rst) live <= init_live;
    else     live <= live | (32'd1 << rd);
endmodule
