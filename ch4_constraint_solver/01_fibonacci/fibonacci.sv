// fibonacci.sv -- a recursive constraint (Chapter 4, fig:fibonacci-recursive).
//
// Pin an array to 10 elements, fix the first two, and constrain every later
// element to the sum of its two predecessors. randomize() finds an assignment
// that satisfies the whole recurrence at once; because the recurrence has a
// single solution, the "random" result is the Fibonacci sequence. A gentle first
// look at randomize() as model-finding before the 9x9 Sudoku of ../02 and ../03.
module tb_top;

  class FibGen;
    rand int unsigned fib[];
    constraint fib_cst {
      fib.size() == 10;
      fib[0] == 0;
      fib[1] == 1;
      foreach (fib[i]) if (i >= 2) fib[i] == fib[i-1] + fib[i-2];
    }
  endclass

  initial begin
    FibGen f;
    f = new();
    if (f.randomize() == 0) $fatal(1, "randomize() failed");
    $write("  fib =");
    foreach (f.fib[i]) $write(" %0d", f.fib[i]);
    $write("\n");
    for (int i = 2; i < 10; i++)
      if (f.fib[i] != f.fib[i-1] + f.fib[i-2]) $fatal(1, "not Fibonacci at index %0d", i);
    $display("  recursive constraint satisfied.");
    $finish;
  end
endmodule
