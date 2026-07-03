// i2c_pkg.sv  --  Earlgrey I2C controller (host + target modes).
package i2c_pkg;

  typedef enum logic [1:0] {
    I2C_HOST   = 0,
    I2C_TARGET = 1
  } i2c_mode_e;

  typedef struct {
    i2c_mode_e          mode;
    int                 scl_freq_khz;       // 100, 400, 1000
    int                 own_target_addr;    // 7-bit, valid in TARGET
    longint unsigned    timestamp_ns;
  } I2cConfig_s;

  // Host-mode SW transaction request (CSR-driven)
  typedef enum logic [1:0] {
    I2C_OP_WRITE    = 0,
    I2C_OP_READ     = 1
  } i2c_op_e;

  typedef struct {
    longint unsigned    id;
    i2c_op_e            op;
    int                 target_addr;        // 7-bit
    bit [7:0]           tx_bytes [];        // for WRITE
    int                 read_len;           // for READ
    bit                 stop;
    longint unsigned    timestamp_ns;
  } I2cTxnReq_s;

  typedef struct {
    longint unsigned    id;
    i2c_op_e            op;
    bit                 acked;              // 1 = target acked address
    bit [7:0]           rx_bytes [];        // for READ
    bit                 nack;               // any byte NACKed
    bit                 timeout;
    longint unsigned    timestamp_ns;
  } I2cTxnRsp_s;

  // Wire-level event for the bus monitor
  typedef enum logic [2:0] {
    I2C_EV_START      = 0,
    I2C_EV_STOP       = 1,
    I2C_EV_BYTE_TX    = 2,
    I2C_EV_BYTE_RX    = 3,
    I2C_EV_ADDR       = 4,
    I2C_EV_NACK       = 5
  } i2c_event_kind_e;

  typedef struct {
    i2c_event_kind_e    kind;
    bit [7:0]           data;
    int                 target_addr;
    longint unsigned    timestamp_ns;
  } I2cBusEvent_s;

endpackage
