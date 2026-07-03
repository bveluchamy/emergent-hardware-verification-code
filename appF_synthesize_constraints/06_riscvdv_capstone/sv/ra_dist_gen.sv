// 06_riscvdv_capstone slice 9: the dist (weighted distribution) family -- riscv-dv ra_c -- as a CONSTRUCTIVE
// weighted sampler. A dist is a weighted table: map a uniform seed through cumulative thresholds to
// the chosen value. A comparator cascade -- no divider, no runtime SAT.
//
// ra dist {1:=3, 6:=2, [2:5]:/1, [7:31]:/4}; ra != {0,2,4}.  The `:/` gives the RANGE a total weight
// split among its members; SV `dist` is renormalized over the FEASIBLE set, and -- the gotcha slice 9
// documents -- the `:/` bucket weight is preserved and split among the SURVIVORS of [2:5] (i.e. {3,5}
// after !=2,!=4 drop 2,4), NOT dropped. So the relative parts are RA 3 : T1 2 : [2:5]-bucket 1 :
// [7:31] 4  =  total 10  (this matches verilator's randomize() of the verbatim constraint).
//
//   support = {0..31}\{0,2,4};  weights scaled to 65536 (sum exactly 65536):
//     RA(1)=19650  {3}=3277  {5}=3277  T1(6)=13107  each of [7:31]=1049  (25*1049=26225)
module ra_dist_gen (input logic [15:0] seed, output logic [4:0] ra);
  always_comb begin
    logic [16:0] cum; logic done; ra = 5'd1; cum = 17'd0; done = 1'b0;
    cum += 17'd19650; if(!done && seed < cum) begin ra=5'd1; done=1; end   // RA,  part 3
    cum += 17'd3277;  if(!done && seed < cum) begin ra=5'd3; done=1; end   // {3,5} = the [2:5] bucket,
    cum += 17'd3277;  if(!done && seed < cum) begin ra=5'd5; done=1; end   //   part 1, split among survivors
    cum += 17'd13107; if(!done && seed < cum) begin ra=5'd6; done=1; end   // T1,  part 2
    for (int v=7; v<32; v++) begin                                        // [7:31], part 4 split 25 ways
      cum += 17'd1049; if(!done && seed < cum) begin ra=v[4:0]; done=1; end
    end
  end
endmodule
