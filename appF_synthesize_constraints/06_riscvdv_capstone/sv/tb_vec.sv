// validate the vector LMUL "multiply" constraints both directions: synthesized actor (shift/mask)
// vs verilator randomize() of the ORIGINAL (modulo/multiply). For each LMUL ∈ {1,2,4,8}.
module tb_top;
  logic [1:0] lmul_sel; logic [4:0] sv2,svd; logic [2:0] snf;
  logic [4:0] vs2, vd; logic [2:0] nfields; logic ok_s, ok_o;
  vlmul_gen   dut(.lmul_sel(lmul_sel), .seed_vs2(sv2), .seed_vd(svd), .seed_nf(snf),
                  .vs2(vs2), .vd(vd), .nfields(nfields));
  vec_checker chk(.lmul_sel(lmul_sel), .vs2(vs2), .vd(vd), .nfields(nfields), .ok(ok_s));
  // a 2nd checker instance for the ORIGINAL's outputs
  logic [4:0] ovs2, ovd; logic [2:0] onf;
  vec_checker chko(.lmul_sel(lmul_sel), .vs2(ovs2), .vd(ovd), .nfields(onf), .ok(ok_o));

  function automatic int unsigned amask(input int unsigned ls);
    int unsigned m, step; m=0; step = 2*(1<<ls);
    for (int g=0; g*step<32; g++) m |= (1 << (g*step));
    return m;
  endfunction
  function automatic int unsigned nmask(input int unsigned ls);
    int unsigned maxnf, m;
    m = 0;
    if (ls==3) return (1<<0);                 // vlmul==8 -> {0}
    maxnf = (8>>ls)-1;
    for (int n=1;n<=maxnf;n++) m|=(1<<n);
    return m;
  endfunction

  vec_orig o = new();
  initial begin
    static int badS=0, badO=0, covfail=0, solved=0, total=0;
    for (int ls=0; ls<4; ls++) begin
      logic [31:0] pVs2s,pVds,pVs2o,pVdo; logic [7:0] pNfs,pNfo;
      pVs2s=0;pVds=0;pVs2o=0;pVdo=0;pNfs=0;pNfo=0;
      lmul_sel = ls[1:0]; o.vlmul = (1<<ls);
      // SYNTH: full nested sweep of the seed space (32*32*8) for complete coverage
      for (int a=0;a<32;a++) for (int b=0;b<32;b++) for (int c=0;c<8;c++) begin
        sv2=a[4:0]; svd=b[4:0]; snf=c[2:0]; #1;
        total++; if(!ok_s) badS++;
        pVs2s[vs2]=1; pVds[vd]=1; pNfs[nfields]=1;
      end
      // ORIGINAL: verilator randomize()
      for (int k=0;k<2000;k++) if (o.randomize()) begin
        solved++; ovs2=o.vs2; ovd=o.vd; onf=o.nfields; #1;
        if(!ok_o) badO++;
        pVs2o[o.vs2]=1; pVdo[o.vd]=1; pNfo[o.nfields]=1;
      end
      // both must cover EXACTLY the aligned groups (vs2,vd) and the valid nfields set
      if (pVs2s !== amask(ls)) begin covfail++; $display("  ls=%0d synth vs2 pool %08h want %08h",ls,pVs2s,amask(ls)); end
      if (pVds  !== amask(ls)) begin covfail++; $display("  ls=%0d synth vd  pool %08h want %08h",ls,pVds, amask(ls)); end
      if (pNfs[7:0] !== nmask(ls)[7:0]) begin covfail++; $display("  ls=%0d synth nf pool %02h want %02h",ls,pNfs,nmask(ls)); end
      if (solved>0) begin
        if (pVs2o !== amask(ls)) begin covfail++; $display("  ls=%0d orig vs2 pool %08h want %08h",ls,pVs2o,amask(ls)); end
        if (pVdo  !== amask(ls)) begin covfail++; $display("  ls=%0d orig vd  pool %08h want %08h",ls,pVdo, amask(ls)); end
        if (pNfo[7:0] !== nmask(ls)[7:0]) begin covfail++; $display("  ls=%0d orig nf pool %02h want %02h",ls,pNfo,nmask(ls)); end
      end
    end
    $display("  [verilator solved ORIGINAL vector %% and * constraint: %0d/8000]", solved);
    if (badS==0 && badO==0 && covfail==0 && solved>0)
      $display(">>> VEC OK: vector LMUL register-group constraints (the only [mul] set in riscv-dv) -- synthesized actor (SHIFT/MASK, no divider) and verilator-solved ORIGINAL (modulo/multiply) BOTH cover exactly the aligned vs2/vd register groups and the valid nfields range for every LMUL in {1,2,4,8}, 0 illegal each");
    else $display(">>> VEC: synthBad=%0d origBad=%0d cov=%0d solved=%0d total=%0d", badS,badO,covfail,solved,total);
    $finish;
  end
endmodule
