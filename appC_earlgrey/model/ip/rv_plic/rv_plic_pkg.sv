// rv_plic_pkg.sv  --  RISC-V PLIC interrupt controller messages.
package rv_plic_pkg;
  typedef struct {
    int              irq_id;          // global PLIC IRQ id
    int              priority_level;
    longint unsigned timestamp_ns;
  } PlicIrqRequest_s;

  typedef struct {
    int              irq_id;          // claimed IRQ id, 0 = none
    int              hart_id;         // 0 = M-mode hart 0
    longint unsigned timestamp_ns;
  } PlicIrqClaim_s;

  typedef struct {
    int              irq_id;
    int              hart_id;
    longint unsigned timestamp_ns;
  } PlicIrqComplete_s;
endpackage
