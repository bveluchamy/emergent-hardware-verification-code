// flash_ctrl_pkg.sv  --  Earlgrey embedded flash controller messages.
//
// Earlgrey-specific. The flash controller manages two banks of embedded
// flash with address-scrambling, ECC, and lifecycle integration. It
// exposes program/erase/read operations through a register-driven
// command interface.

package flash_ctrl_pkg;

  typedef enum logic [1:0] {
    FLASH_OP_READ  = 0,
    FLASH_OP_PROG  = 1,
    FLASH_OP_ERASE = 2
  } flash_op_e;

  typedef enum logic [1:0] {
    FLASH_PART_DATA = 0,
    FLASH_PART_INFO = 1
  } flash_part_e;

  typedef struct {
    flash_op_e       op;
    flash_part_e     partition;
    logic [31:0]     addr;       // word address in flash space
    logic [31:0]     data;       // for PROG; ignored otherwise
    int              num_words;  // for READ/ERASE
    longint unsigned timestamp_ns;
  } FlashCmd_s;

  typedef struct {
    flash_op_e       op;
    logic [31:0]     addr;
    logic [31:0]     data;
    bit              done;
    bit              error;
    string           error_reason;
    longint unsigned timestamp_ns;
  } FlashRsp_s;

  typedef struct {
    bit              data_part_locked;     // BL0 locked from program/erase?
    bit              info_part_locked;
    bit              creator_seed_valid;   // for keymgr binding
    bit              owner_seed_valid;
  } FlashStatus_s;

endpackage
