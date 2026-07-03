# appC_earlgrey/tools

Framework-level tools that any actor-based testbench can use.

## reggen_actor.py

Generates an `actor_ral_pkg::RalActor` register-definition function from
an OpenTitan-style register Hjson file. The output is a SystemVerilog
package with one `define_<ip>_ral(ral)` function that the per-IP env
calls in its constructor:

```sv
import uart_ral_defs_pkg::*;
...
ral = new("uart.ral");
define_uart_ral(ral);
```

This is the framework's analogue of OpenTitan's `reggen`. Same
input format, much smaller output (no four-copy Mirrored / Desired /
Reset / Value state machine), single-copy definitions plus backdoor
access via `RalBackdoor`.

### Usage

```sh
# Generate from an OpenTitan IP's Hjson
tools/reggen_actor.py /path/to/ip.hjson --pkg ip_ral_defs_pkg > ip_ral_defs.sv

# Custom function name
tools/reggen_actor.py uart.hjson --fn-name my_uart_ral_defs > out.sv
```

### Hjson format supported

The tool accepts the canonical OpenTitan reggen input shape:

```hjson
{
  name: "uart"
  regwidth: "32"
  registers: [
    { name: "INTR_STATE", swaccess: "rw1c", resval: "0"
      fields: [
        { bits: "0", name: "tx_watermark" }
        { bits: "1", name: "rx_watermark" }
      ]
    }
    { skipto: "0x10" }                  # jump to absolute offset
    { reserved: 4 }                     # reserve N register slots
    { name: "CTRL", swaccess: "rw"
      fields: [
        { bits: "7:0",   name: "DATA"   }
        { bits: "31:16", name: "MASK"   }
      ]
    }
  ]
  memories: [                            # optional, framework extension
    { name: "buffer"
      base_addr: "0x100"
      size_bytes: "256"
      backdoor_root: "tb.dut.uart.buf"
    }
  ]
}
```

Access policies recognized: `rw`, `ro`, `wo`, `rc`, `rw1c` (== `w1c`),
`rw0c` (== `w0c`), `r0w1c`. Unknown policies fall back to `RW`.

Parameterized field widths (e.g. `bits: "HashCntW-1:0"` from KMAC) fall
back to a full-word field; the user can hand-edit the generated file
in those cases. The tool does not resolve Hjson parameter expressions.

### Dependencies

- Python 3.6+
- `hjson` Python package (optional but recommended; falls back to
  strict JSON if unavailable)

### Output as a framework-managed artifact

The generated file is a build artifact: re-run the tool whenever the
spec changes. The recommended workflow is to regenerate as part of the
testbench build (a Makefile rule that depends on the `.hjson` source).
The example in `appC_earlgrey/` ships pre-generated
files for inspection.
