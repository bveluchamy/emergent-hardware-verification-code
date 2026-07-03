// irq_pkg.sv
//
// Interrupt protocol for the OpenTitan-as-actors example.
//
// In silicon, IPs raise interrupt lines that go to the PLIC, which routes
// them to the Ibex CPU. In the actor model, "raising an interrupt" is
// publishing an IrqMsg_s. Subscribers can be a CpuActor (real handling),
// a CoverageActor (sample which IRQs fire when), or a ScoreboardActor
// (verify expected IRQ patterns).
//
// IRQ enable/clear is also a message type so the same observability
// machinery covers register-side mask configuration changes.

package irq_pkg;

  typedef struct {
    string  source_name;     // e.g. "uart0", "aon_timer"
    int     vector_id;       // PLIC vector
    int     priority_level;  // PLIC priority
    longint unsigned timestamp_ns;
  } IrqMsg_s;

  // CPU/test side responding to / clearing an interrupt
  typedef struct {
    int     vector_id;
    bit     handled;         // 1 = ISR ran, 0 = explicitly ignored
  } IrqAck_s;

  // Configuration/mask change observable on the bus
  typedef struct {
    string  source_name;
    int     vector_id;
    bit     enable;
  } IrqEnableChange_s;

endpackage
