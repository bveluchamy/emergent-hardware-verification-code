// rom_ctrl_pkg.sv
//
// Earlgrey ROM controller. Verifies the ROM image's KMAC-based hash on
// every boot and only releases the result to keymgr/lc_ctrl/pwrmgr if
// the hash matches.

package rom_ctrl_pkg;

  // Hash check result -- broadcast once per boot
  typedef struct {
    bit              hash_match;     // 1 if computed hash matches OTP digest
    logic [255:0]    computed_hash;
    logic [255:0]    expected_hash;
    longint unsigned timestamp_ns;
  } RomHashCheck_s;

endpackage
