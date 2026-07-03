// rv_plic_actor.sv  --  RISC-V PLIC: routes IRQs from any source to Ibex.
import actor_pkg::*;
import rv_plic_pkg::*;
import irq_pkg::*;

class RvPlicActor extends Actor;
  // Pending IRQs, ordered by priority (highest first)
  PlicIrqRequest_s    pending_q [$];
  // Currently-claimed IRQ; only one outstanding at a time
  int                 active_irq;
  bit                 active_valid;

  function new(string name = "rv_plic");
    super.new(name);
    active_irq    = 0;
    active_valid  = 1'b0;
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(IrqMsg_s): begin
        IrqMsg_s         i = Msg#(IrqMsg_s)::unwrap(msg);
        PlicIrqRequest_s r;
        r.irq_id          = i.vector_id;
        r.priority_level  = i.priority_level;
        r.timestamp_ns    = $time;
        insert_sorted(r);
        forward_top();
      end
      $typename(PlicIrqClaim_s): begin
        // Hart claims the highest-priority pending IRQ
        if (pending_q.size() > 0) begin
          PlicIrqClaim_s claim;
          PlicIrqRequest_s top = pending_q.pop_front();
          claim.irq_id        = top.irq_id;
          claim.hart_id       = 0;
          claim.timestamp_ns  = $time;
          active_irq          = top.irq_id;
          active_valid        = 1'b1;
          `PUBLISH(claim);
        end
      end
      $typename(PlicIrqComplete_s): begin
        active_valid = 1'b0;
        forward_top();
      end
    endcase
  endtask

  function void insert_sorted(PlicIrqRequest_s req);
    int idx = 0;
    while (idx < pending_q.size() && pending_q[idx].priority_level >= req.priority_level)
      idx++;
    pending_q.insert(idx, req);
  endfunction

  function void forward_top();
    if (pending_q.size() == 0 || active_valid) return;
    // Forward the highest-pri request as a "raise" event the CPU will see.
    `PUBLISH(pending_q[0]);
  endfunction
endclass
