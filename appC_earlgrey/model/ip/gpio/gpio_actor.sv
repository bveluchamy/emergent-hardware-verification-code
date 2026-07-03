// gpio_actor.sv  --  Earlgrey GPIO controller.
import actor_pkg::*;
import gpio_pkg::*;
import irq_pkg::*;

class GpioActor extends Actor;
  logic [31:0]   out_value;
  logic [31:0]   out_enable;
  logic [31:0]   in_value;
  logic [31:0]   intr_enable;       // 1 = pin generates IRQ on change

  function new(string name = "gpio");
    super.new(name);
    out_enable  = 32'h0000_FFFF;    // bottom 16 = outputs by default
    intr_enable = 32'h0;
  endfunction

  function void enable_intr(logic [31:0] mask);
    intr_enable = mask;
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(GpioSetCmd_s): begin
        GpioSetCmd_s c = Msg#(GpioSetCmd_s)::unwrap(msg);
        out_value = (out_value & ~c.mask) | (c.data & c.mask);
        publish_state();
      end
      $typename(GpioInputChange_s): begin
        GpioInputChange_s c = Msg#(GpioInputChange_s)::unwrap(msg);
        logic prev = in_value[c.pin];
        in_value[c.pin] = c.value;
        if (prev !== c.value && intr_enable[c.pin]) begin
          GpioIntr_s ie;
          IrqMsg_s   irq;
          ie.pin            = c.pin;
          ie.new_value      = c.value;
          ie.timestamp_ns   = $time;
          `PUBLISH(ie);
          irq.source_name   = name;
          irq.vector_id     = c.pin;
          irq.priority_level = 1;
          irq.timestamp_ns  = $time;
          `PUBLISH(irq);
        end
        publish_state();
      end
    endcase
  endtask

  function void publish_state();
    GpioState_s s;
    s.out_value     = out_value & out_enable;
    s.in_value      = in_value;
    s.out_enable    = out_enable;
    s.timestamp_ns  = $time;
    `PUBLISH(s);
  endfunction
endclass
