// otp_ctrl_pkg.sv  --  Earlgrey OTP fuse controller.
//
// OTP holds creator/owner secrets, lifecycle state, ROM hash digest, and
// other one-time-burnt values. Most reads are SW-driven through the bus.
// Boot-time, OTP also drives sideband signals to keymgr / lc_ctrl /
// rom_ctrl with their seed values.

package otp_ctrl_pkg;

  typedef enum int {
    OTP_PART_VENDOR_TEST     = 0,
    OTP_PART_CREATOR_SW_CFG  = 1,
    OTP_PART_OWNER_SW_CFG    = 2,
    OTP_PART_HW_CFG0         = 3,
    OTP_PART_HW_CFG1         = 4,
    OTP_PART_SECRET0         = 5,
    OTP_PART_SECRET1         = 6,
    OTP_PART_SECRET2         = 7,
    OTP_PART_LIFE_CYCLE      = 8
  } otp_part_e;

  typedef struct {
    logic [255:0]   creator_root_seed;
    logic [255:0]   creator_diversification_key;
    logic [255:0]   owner_seed;
    logic [255:0]   rom_hash_digest;
    int             lc_state;
    longint unsigned timestamp_ns;
  } OtpInitDone_s;

  typedef struct {
    otp_part_e      partition;
    logic [31:0]    addr;
    logic [31:0]    data;
    bit             write;     // 0 = read; OTP can also be programmed (one time)
  } OtpCmd_s;

  typedef struct {
    otp_part_e      partition;
    logic [31:0]    addr;
    logic [31:0]    data;
    bit             error;
  } OtpRsp_s;

endpackage
