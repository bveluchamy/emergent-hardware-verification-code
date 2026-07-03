// actor_ral_pkg.sv
//
// Register Abstraction Layer (RAL) as a framework primitive.
//
// This is intentionally NOT a port of UVM's uvm_reg / uvm_reg_field
// hierarchy. UVM's RAL maintains four copies of every field's value
// (Desired, Mirrored, Reset, Value) plus a predictor that updates the
// mirrored copy from observed bus traffic. For CSR-heavy SoCs that is
// gigabytes of testbench state shadowing state that already lives in
// the RTL. Most of it is dead weight in the common case (read-this-
// register-check-this-field).
//
// The actor-model RAL keeps a different bargain. Definitions are
// immutable contract data: name, address, bit slice, access policy,
// reset value. Current values are NOT shadowed -- they live in the
// RTL (or in the IP-actor's slave-side backing store) and are read
// via backdoor when a test needs them. The bus monitor's stream of
// TlulMonPkt_s gets translated to symbolic RalEvent_s for downstream
// coverage / trace / scoreboard subscribers; nothing reconstructs a
// mirrored state because the mirrored state would just be a stale
// copy of the RTL.
//
// Memories follow the same rule with even less state: a memory is
// just a (base_addr, size, backdoor_root) triple. Reads and writes
// pass through to the actual storage.
//
// API surface:
//   define_reg / define_field / define_mem -- populate the contract
//   addr_of(name)         : symbolic name  -> physical address
//   name_at(addr)         : physical addr  -> symbolic name (reverse)
//   field_info(name)      : symbolic name  -> (lsb, width, access, reset)
//   read_field(name)      : backdoor pass-through to RTL field
//   write_field(name, v)  : backdoor pass-through to RTL field
//   read_mem(name, off)   : backdoor pass-through to memory cell
//   write_mem(name, off, v): backdoor pass-through to memory cell
//
// Auto-generation: appC_earlgrey/tools/reggen_actor.py emits the
// define_* body from an OpenTitan-style Hjson register description,
// the same way OpenTitan's `reggen --uvm` emits UVM RAL classes.

package actor_ral_pkg;

  import actor_pkg::*;

  typedef enum logic [3:0] {
    RAL_RW   = 0,    // read/write
    RAL_RO   = 1,    // read-only (writes ignored)
    RAL_W1C  = 2,    // write 1 to clear (e.g. interrupt status)
    RAL_W0C  = 3,    // write 0 to clear
    RAL_WO   = 4,    // write-only (reads return 0)
    RAL_RC   = 5     // read-clear (read returns then clears)
  } ral_access_e;

  typedef struct {
    string         name;
    logic [31:0]   addr;
    logic [31:0]   reset_value;
    ral_access_e   access;
  } ral_reg_def_t;

  typedef struct {
    string         reg_name;        // parent register name
    string         field_name;      // field name (unique within reg)
    int            lsb;
    int            width;
    ral_access_e   access;
    logic [31:0]   reset_value;
  } ral_field_def_t;

  typedef struct {
    string         name;
    logic [31:0]   base_addr;
    longint unsigned size_bytes;
    string         backdoor_root;   // SV hierarchical path; empty if none
  } ral_mem_def_t;

  // Symbolic event published when the RAL's bus subscriber translates
  // an observed TlulMonPkt_s into a known register access.
  typedef struct {
    string             reg_name;
    logic [31:0]       addr;
    logic [31:0]       value;       // wdata for writes, rdata for reads
    bit                is_write;
    longint unsigned   timestamp_ns;
  } RalEvent_s;

  // Read/write handle abstraction for backdoor access. In real silicon
  // testbenches this is a virtual interface to the DUT's hierarchical
  // path. For the example DUTs we plug in a behavioral implementation
  // that talks to the IP-actor's slave-side backing store; for real RTL
  // you'd plug in a wrapper that uses SystemVerilog hierarchical refs.
  // Subclass and override to do the actual access.
  virtual class RalBackdoor;
    pure virtual function logic [31:0] read_addr(logic [31:0] addr);
    pure virtual function void         write_addr(logic [31:0] addr,
                                                  logic [31:0] value);
  endclass

  class RalActor extends Actor;
    // Forward maps
    ral_reg_def_t      regs   [string];
    ral_field_def_t    fields [string];   // key: "<reg>.<field>"
    ral_mem_def_t      mems   [string];

    // Reverse map for fast bus-traffic decode
    string             name_by_addr [logic [31:0]];

    // Backdoor handle. Optional: tests that don't need backdoor
    // access can leave it null. Set via attach_backdoor().
    RalBackdoor        backdoor;

    // Block base address. Register-table addresses are stored as
    // block-relative offsets; addr_of() returns absolute addresses by
    // adding this base. Default 0 treats the table as absolute.
    logic [31:0]       addr_offset;

    function new(string name = "RalActor");
      super.new(name);
      addr_offset = 32'h0;
    endfunction

    function void attach_backdoor(RalBackdoor bd);
      backdoor = bd;
    endfunction

    function void set_addr_offset(logic [31:0] base_addr);
      addr_offset = base_addr;
    endfunction

    // ---- Definition population ----

    function void define_reg(string         name_,
                             logic [31:0]   addr,
                             ral_access_e   access,
                             logic [31:0]   reset_value = 32'h0);
      ral_reg_def_t r;
      r.name        = name_;
      r.addr        = addr;
      r.reset_value = reset_value;
      r.access      = access;
      regs[name_]   = r;
      name_by_addr[addr] = name_;
    endfunction

    function void define_field(string         reg_name,
                               string         field_name,
                               int            lsb,
                               int            width,
                               ral_access_e   access,
                               logic [31:0]   reset_value = 32'h0);
      ral_field_def_t f;
      f.reg_name    = reg_name;
      f.field_name  = field_name;
      f.lsb         = lsb;
      f.width       = width;
      f.access      = access;
      f.reset_value = reset_value;
      fields[{reg_name, ".", field_name}] = f;
    endfunction

    function void define_mem(string             name_,
                             logic [31:0]       base_addr,
                             longint unsigned   size_bytes,
                             string             backdoor_root = "");
      ral_mem_def_t m;
      m.name           = name_;
      m.base_addr      = base_addr;
      m.size_bytes     = size_bytes;
      m.backdoor_root  = backdoor_root;
      mems[name_]      = m;
    endfunction

    // ---- Symbolic queries ----

    function logic [31:0] addr_of(string reg_name);
      if (!regs.exists(reg_name))
        $fatal(1, "RalActor::addr_of: unknown register '%s'", reg_name);
      return regs[reg_name].addr + addr_offset;
    endfunction

    function string name_at(logic [31:0] absolute_addr);
      logic [31:0] reg_offset = absolute_addr - addr_offset;
      return name_by_addr.exists(reg_offset) ? name_by_addr[reg_offset] : "";
    endfunction

    function ral_field_def_t field_info(string field_qname);
      if (!fields.exists(field_qname))
        $fatal(1, "RalActor::field_info: unknown field '%s'", field_qname);
      return fields[field_qname];
    endfunction

    function logic [31:0] reset_value_of(string reg_name);
      return regs.exists(reg_name) ? regs[reg_name].reset_value : 32'h0;
    endfunction

    // ---- Backdoor access (no shadow state, no predictor) ----

    function logic [31:0] read_field(string field_qname);
      ral_field_def_t f;
      logic [31:0]    word;
      if (backdoor == null)
        $fatal(1, "RalActor::read_field: no backdoor attached");
      f    = field_info(field_qname);
      // addr_of(), not the raw table entry: register addresses are stored
      // block-relative, and the backdoor speaks absolute addresses once
      // set_addr_offset() has been applied (exactly as read_reg does).
      word = backdoor.read_addr(addr_of(f.reg_name));
      return (word >> f.lsb) & ((1 << f.width) - 1);
    endfunction

    function void write_field(string field_qname, logic [31:0] value);
      ral_field_def_t f;
      logic [31:0]    word, mask;
      if (backdoor == null)
        $fatal(1, "RalActor::write_field: no backdoor attached");
      f    = field_info(field_qname);
      mask = ((1 << f.width) - 1) << f.lsb;
      word = backdoor.read_addr(addr_of(f.reg_name));
      word = (word & ~mask) | ((value << f.lsb) & mask);
      backdoor.write_addr(addr_of(f.reg_name), word);
    endfunction

    function logic [31:0] read_reg(string reg_name);
      if (backdoor == null)
        $fatal(1, "RalActor::read_reg: no backdoor attached");
      return backdoor.read_addr(addr_of(reg_name));
    endfunction

    function void write_reg(string reg_name, logic [31:0] value);
      if (backdoor == null)
        $fatal(1, "RalActor::write_reg: no backdoor attached");
      backdoor.write_addr(addr_of(reg_name), value);
    endfunction

    // Memory base addresses follow the register convention: stored
    // block-relative, made absolute with addr_offset here.
    function logic [31:0] read_mem(string mem_name, logic [31:0] offset);
      if (!mems.exists(mem_name) || backdoor == null)
        $fatal(1, "RalActor::read_mem: unknown mem or no backdoor");
      return backdoor.read_addr(addr_offset + mems[mem_name].base_addr + offset);
    endfunction

    function void write_mem(string mem_name, logic [31:0] offset,
                            logic [31:0] value);
      if (!mems.exists(mem_name) || backdoor == null)
        $fatal(1, "RalActor::write_mem: unknown mem or no backdoor");
      backdoor.write_addr(addr_offset + mems[mem_name].base_addr + offset, value);
    endfunction

    // ---- Bus-side observation ----
    // The RAL is wired to its IP's bus monitor via `WIRE(monitor, BusTxn,
    // ral) in the env, and re-publishes each observed transaction as a
    // symbolic RalEvent_s with the resolved register name. Subscribers
    // that care about specific registers (a coverage actor, a trace
    // recorder, a scoreboard hook) wire to the RalActor instead of
    // decoding the raw bus stream themselves.
    //
    // The raw struct passed into act() carries an `addr`, an `is_write`
    // flag, and a value. Any monitor-side struct that has these fields
    // can be plugged in; the canonical one is tlul_pkg::TlulMonPkt_s,
    // but the framework deliberately doesn't import it here so this
    // package stays bus-protocol-agnostic. See
    // earlgrey examples for the TL-UL adapter pattern.

    virtual task act(MsgBase msg);
      // Subclass per protocol to translate the raw bus packet into a
      // RalEvent_s. Default: no-op.
    endtask
  endclass

endpackage
