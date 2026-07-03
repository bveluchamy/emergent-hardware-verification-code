// spi_device_pkg.sv  --  Earlgrey SPI device (target).
//
// In silicon spi_device has three modes: generic (FIFO-based), flash
// (emulates a SPI NOR flash for boot), and TPM (Trusted Platform Module
// command set). We model the mode and the most-common transactions.

package spi_device_pkg;

  typedef enum logic [1:0] {
    SPID_MODE_GENERIC = 0,
    SPID_MODE_FLASH   = 1,
    SPID_MODE_TPM     = 2
  } spid_mode_e;

  typedef struct {
    spid_mode_e        mode;
    int                cpha_cpol;          // mode 0..3
    longint unsigned   timestamp_ns;
  } SpiDeviceConfig_s;

  // External SPI host drives one transaction
  typedef struct {
    bit [7:0]          cmd_byte;            // first byte after CS asserts
    bit [7:0]          payload [];          // host->device bytes
    int                read_len;            // bytes the host expects back
    longint unsigned   timestamp_ns;
  } SpiDeviceTxn_s;

  // SPI device publishes a response when it has data to return
  typedef struct {
    bit [7:0]          cmd_byte;
    bit [7:0]          response [];         // device->host bytes
    bit                error;
    longint unsigned   timestamp_ns;
  } SpiDeviceRsp_s;

  // Flash-mode commands the actor emulates
  parameter logic [7:0] SPID_FLASH_READ_JEDEC_ID  = 8'h9F;
  parameter logic [7:0] SPID_FLASH_READ           = 8'h03;
  parameter logic [7:0] SPID_FLASH_FAST_READ      = 8'h0B;
  parameter logic [7:0] SPID_FLASH_PAGE_PROGRAM   = 8'h02;
  parameter logic [7:0] SPID_FLASH_WRITE_ENABLE   = 8'h06;
  parameter logic [7:0] SPID_FLASH_READ_STATUS_R1 = 8'h05;

  // TPM-mode commands
  parameter logic [7:0] SPID_TPM_GO_IDLE          = 8'h00;
  parameter logic [7:0] SPID_TPM_DATA_FIFO        = 8'h24;

endpackage
