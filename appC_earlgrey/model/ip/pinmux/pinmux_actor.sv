// pinmux_actor.sv  --  configuration table that routes signals to pads.
import actor_pkg::*;
import pinmux_pkg::*;

class PinmuxActor extends Actor;
  // pad_index -> {direction, signal_id}
  typedef struct {
    pinmux_direction_e direction;
    int                signal_id;
  } pad_route_t;
  pad_route_t   route_table [int];

  // pad_index -> attributes
  PinmuxPadAttr_s pad_attr [int];

  function new(string name = "pinmux_aon");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(PinmuxCfg_s): begin
        PinmuxCfg_s c = Msg#(PinmuxCfg_s)::unwrap(msg);
        pad_route_t r;
        r.direction          = c.direction;
        r.signal_id          = c.signal_id;
        route_table[c.pad_index] = r;
      end
      $typename(PinmuxPadAttr_s): begin
        PinmuxPadAttr_s p = Msg#(PinmuxPadAttr_s)::unwrap(msg);
        pad_attr[p.pad_index] = p;
      end
    endcase
  endtask

  // Test API: query the current routing
  function int signal_at_pad(int pad_index);
    if (route_table.exists(pad_index)) return route_table[pad_index].signal_id;
    return -1;
  endfunction

  function int routes_count();
    return route_table.size();
  endfunction
endclass
