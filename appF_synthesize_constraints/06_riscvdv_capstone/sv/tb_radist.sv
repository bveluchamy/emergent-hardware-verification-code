// validate the dist family both directions: the constructive weighted sampler vs verilator
// randomize() of the VERBATIM ra_c. The sampler's distribution is EXACT by construction, so we verify
// the weight table at BUCKET BOUNDARIES (exact, no 65536-sweep) + spot-check support, then compare
// the original's sampled histogram to the KNOWN exact fractions (the weight constants).
module tb_top;
  logic [15:0] seed; logic [4:0] ra; logic ok;
  ra_dist_gen dut(.seed(seed), .ra(ra));
  ra_checker  chk(.ra(ra), .ok(ok));

  // exact weights (sum 65536, parts=10): RA(1)=19650 {3}=3277 {5}=3277 T1(6)=13107 each[7:31]=1049.
  function automatic int unsigned synthW(int v);
    if (v==1) return 19650; if (v==3 || v==5) return 3277; if (v==6) return 13107;
    if (v>=7 && v<=31) return 1049; return 0;
  endfunction
  // |a/AN - b/BN| < tol*(b/BN) as integers (no reals): |a*BN - b*AN| <= tol% * b * AN
  function automatic bit close(longint a, longint AN, longint b, longint BN, int tol_pct);
    longint lhs = (a*BN > b*AN) ? (a*BN - b*AN) : (b*AN - a*BN);
    return (lhs <= (tol_pct * b * AN) / 100);
  endfunction

  ra_orig o = new();
  initial begin
    static longint hO[32]; static int badS=0, badO=0, solved=0, weightfail=0, bndfail=0, suppfail=0, N=4000;
    // bucket boundaries: {first seed, last seed, expected ra} -- exact verification of the weight table
    static int unsigned bnd [0:28][0:2];
    int unsigned base;
    for (int i=0;i<32;i++) hO[i]=0;
    bnd[0]='{0,19649,1}; bnd[1]='{19650,22926,3}; bnd[2]='{22927,26203,5}; bnd[3]='{26204,39310,6};
    base=39311; for (int v=7; v<=31; v++) bnd[v-3]='{base+(v-7)*1049, base+(v-7)*1049+1048, v};

    // ---- SYNTH: boundary checks (exact weight table, no sweep) ----
    for (int i=0;i<29;i++) begin
      seed=bnd[i][0][15:0]; #1; if (ra!==bnd[i][2][4:0] || !ok) bndfail++;
      seed=bnd[i][1][15:0]; #1; if (ra!==bnd[i][2][4:0] || !ok) bndfail++;
    end
    // ---- SYNTH: support spot-check ----
    for (int k=0;k<3000;k++) begin seed=16'(k*21841+7); #1; if(!ok || ra inside{0,2,4}) badS++; end

    // ---- ORIGINAL: verilator randomize() of the verbatim dist ----
    $display("  [synth checks done: bndfail=%0d badS=%0d -- starting %0d dist randomize() draws]", bndfail, badS, N);
    for (int k=0;k<N;k++) if (o.randomize()) begin solved++; if(o.ra inside{0,2,4}) badO++; hO[o.ra]++; end
    $display("  [dist randomize done: solved=%0d]", solved);
    $display("  HIST: ra1=%0d ra3=%0d ra5=%0d ra6=%0d ra7=%0d ra8=%0d ra31=%0d  (of %0d)",
             hO[1],hO[3],hO[5],hO[6],hO[7],hO[8],hO[31], solved);

    // weight fidelity (GROUPED so the tolerance holds at moderate N): RA / T1 / {3,5} / [7:31].
    if (solved>0) begin
      longint g35, grng;
      g35 = hO[3]+hO[5];
      grng = 0;
      for (int v=7; v<=31; v++) grng += hO[v];
      if (!close(hO[1],  solved, 19650, 65536, 15)) begin weightfail++; $display("  RA group: orig %0d/%0d vs 19650/65536",   hO[1], solved); end
      if (!close(hO[6],  solved, 13107, 65536, 15)) begin weightfail++; $display("  T1 group: orig %0d/%0d vs 13107/65536",   hO[6], solved); end
      if (!close(g35,    solved,  6554, 65536, 20)) begin weightfail++; $display("  {3,5} group: orig %0d/%0d vs 6554/65536", g35,   solved); end
      if (!close(grng,   solved, 26225, 65536, 15)) begin weightfail++; $display("  [7:31] group: orig %0d/%0d vs 26225/65536", grng, solved); end
      // every support value is REACHED by the original solver
      for (int v=1; v<=31; v++) if (v!=2 && v!=4 && hO[v]==0) suppfail++;
    end

    $display("  [synth boundary checks: %0d fail | support spot: %0d bad | verilator solved dist: %0d/%0d | suppReach fail: %0d]",
             bndfail, badS, solved, N, suppfail);
    if (bndfail==0 && badS==0 && badO==0 && solved>0 && weightfail==0 && suppfail==0)
      $display(">>> RADIST OK: dist (weighted distribution) family -- riscv-dv ra_c VERBATIM. Constructive weighted sampler (exact dist by construction, weight table verified at all 29 bucket boundaries: RA 30%%, T1 20%%, [7:31] 40%%, {3,5} 10%%) and verilator-randomize()-solved ORIGINAL dist BOTH have support {0..31}\\{ZERO,sp,tp}, every support value reached, and MATCHING grouped weights (orig sampled fractions within 15-20%% of the exact weights over 4000 draws), 0 illegal each");
    else $display(">>> RADIST: bndfail=%0d synthBad=%0d origBad=%0d solved=%0d weightfail=%0d", bndfail,badS,badO,solved,weightfail);
    $finish;
  end
endmodule
