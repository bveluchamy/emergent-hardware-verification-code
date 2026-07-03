// aon_timer_if.sv  -- always-on clock domain interface for the AON timer.
interface aon_timer_if(input logic aon_clk_i, input logic aon_rst_ni);
  // No data signals at this level -- the timer state is internal
  // to the actor model. In real silicon, there would be wakeup_o,
  // wkup_intr_o, bark_o, bite_o, etc.
endinterface
