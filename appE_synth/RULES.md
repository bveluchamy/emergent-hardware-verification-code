# Synthesizable form of the actor framework

The full `actor_pkg` SystemVerilog implementation uses class objects, dynamic
mailboxes, virtual dispatch, and `fork`/`join` — none of which are
synthesizable. The actor *pattern* itself is synthesizable when restricted
to a disciplined subset.

This document defines the rules. The worked examples in
`appE_synth/examples/` follow them and pass Verilator lint plus
Yosys synthesis to a netlist.

## What an actor becomes in synthesizable form

A class-based actor:

```sv
class CounterActor extends Actor;
  int count;
  task act(MsgBase msg);
    count++;
    `PUBLISH(count);
  endtask
endclass
```

The synthesizable equivalent is a SystemVerilog module with explicit
ready/valid handshakes on each direction:

```sv
module CounterActor #(parameter int MSG_W = 32)(
  input  logic               clk_i,
  input  logic               rst_ni,
  // inbound channel
  input  logic               in_valid_i,
  output logic               in_ready_o,
  input  logic [MSG_W-1:0]   in_data_i,
  // outbound channel
  output logic               out_valid_o,
  input  logic               out_ready_i,
  output logic [MSG_W-1:0]   out_data_o
);
  // local state, FSM, output drive
endmodule
```

The translation is mechanical:

| Class-based concept | Synthesizable form |
|---|---|
| `mailbox #(MsgT) mbox` (unbounded) | input ready/valid pair + optional FIFO of fixed depth |
| `forever begin mbox.get(msg); act(msg); end` | always_ff state machine; "got a message" condition is `in_valid_i && in_ready_o` |
| `act(msg)` body (single-handler) | combinational/sequential state-update logic |
| `publish(out)` | output ready/valid pair driven from FSM state |
| `` `WIRE(prod, T, sub) `` (topology) | direct wire connection at elaboration in the parent module |
| Multi-subscriber fan-out | broadcast wire to N consumers, each with its own ready signal |
| Backpressure (`try_publish` returning bit) | `out_valid_o && !out_ready_i` is the stall condition the FSM observes |
| Trace ID propagation | becomes part of the message bundle: bundle has `data` + `trace_id` fields |

## The five rules

1. **No dynamic allocation.** No `new()`, no growing queues, no
   recursion. Mailbox depth is a parameter; if zero the actor accepts
   one message at a time directly into its registers.

2. **No virtual dispatch in the hot path.** A class hierarchy may be
   used during elaboration to generate parameterized modules (the same
   way Chisel and Amaranth generate hardware), but at runtime the
   handler is a fixed FSM, not a virtual call.

3. **Bounded mailboxes only.** Every queue in the design has a
   parameter for depth. Depth is set at elaboration. The synthesizable
   FIFO primitive is `prim_fifo_sync` (OpenTitan), a custom inferred
   FIFO, or any standard library equivalent.

4. **Fixed-cardinality fan-out.** `` `WIRE `` declarations at elaboration
   bind a known set of subscribers; the topology is set at
   `before_end_of_elaboration` (SystemC) or generate-block resolution
   (SystemVerilog). Dynamic subscription/unsubscription is not
   synthesizable.

5. **Ready/valid handshake on every channel.** Ready/valid (or stall/decoupled)
   on both inbound and outbound message channels. Never assume the
   downstream actor is always ready; that constraint is verified at
   architecture-exploration time on the SystemVerilog (or SystemC)
   side and enforced at synthesis time by the handshake.

## The output register: write the general form, let synthesis collapse it

The template registers its output channel — `out_data_q` and `out_valid_q`
are flip-flops, so every actor presents a registered, backpressure-safe
output (Rule 5). Keep that shape even when it looks redundant for a
particular actor.

For most actors the output payload is *not* the same as the local state — a
scoreboard emits a pass/fail verdict, a filter emits a transformed sample, a
decoder emits a different field than it stores — so `out_data_q` is a genuine,
distinct register that must be written explicitly.

The `counter_actor` is the degenerate case where the value it emits
(`count + 1`) is exactly its next state, so `out_data_q` carries the same
value as `count_q` on every cycle. It is provable by induction: both reset to
`0`, on each `in_fire` both take `count_q + 1` (note `out_data_d` keys off
`count_q`, not `out_data_q`), and otherwise both hold. Yosys proves the two
registers congruent and merges them, which is why `make synth` reports **33**
flip-flops — a 32-bit count plus the output-valid latch — not the 65 bits the
module declares.

This is the intended division of labor, not an accident: **author the actor in
the general registered-output form, and let synthesis remove whatever is
redundant in the specific instance.** Do not hand-delete `out_data_q` to make
the counter's bit count line up — that would make the counter unrepresentative
of every other actor, whose output register does not collapse. The template's
job is to be correct for the general case; the tool's job is to make each
instance as small as it can be.

## What is and is not allowed

| Allowed | Not allowed (in synthesizable region) |
|---|---|
| Bounded `prim_fifo_sync` mailboxes | `mailbox #(T)` with no capacity |
| `always_ff @(posedge clk)` FSMs in `act()` | `task` with `@(posedge clk)` blocking |
| Static `case` dispatch on message type tag | Virtual method dispatch |
| `for` loops with bounded constants | `forever`, `while` with non-constant bounds |
| Generate blocks for parameterized topology | Runtime `fork`/`join` |
| Packed structs for typed messages | Class-based payloads |
| Inferred or library FIFOs for buffering | Software-side `mbox.get()` |

## What is gained

The translation is mechanical, which is the point. An actor-aware
synthesis tool — or an HLS frontend that recognises the pattern — can
emit the synthesizable form from the class-based description. Until
that tool exists, the worked examples in this directory are the
manually-translated equivalents, used to:

- Verify with Verilator lint that the structure is well-formed.
- Synthesize through Yosys to a gate-level netlist, demonstrating
  that the actor pattern produces real hardware.
- Establish a reference for a future actor-DSL that would emit
  this form automatically.

## What is next

A SystemC HLS preset (Catapult, Stratus, or Vivado HLS) tuned for the
actor pattern would close the loop: SystemC actors written as in
Appendix E synthesize to RTL through the existing HLS tool chain
without intermediate manual translation.
