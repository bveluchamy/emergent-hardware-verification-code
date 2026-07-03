// spi_host_pkg.sv  --  Earlgrey SPI host (master) controller.
package spi_host_pkg;

  typedef enum logic [1:0] {
    SPI_MODE_0 = 0,    // CPOL=0, CPHA=0
    SPI_MODE_1 = 1,
    SPI_MODE_2 = 2,
    SPI_MODE_3 = 3
  } spi_mode_e;

  typedef struct {
    spi_mode_e          mode;
    int                 sck_freq_mhz;
    int                 cs_index;            // which CS line to assert
    longint unsigned    timestamp_ns;
  } SpiHostConfig_s;

  // SW issues a transaction (segment-based, like real spi_host)
  typedef enum logic [1:0] {
    SPI_SEG_DUMMY        = 0,
    SPI_SEG_TX_ONLY      = 1,
    SPI_SEG_RX_ONLY      = 2,
    SPI_SEG_BIDIR        = 3
  } spi_seg_kind_e;

  typedef struct {
    spi_seg_kind_e      kind;
    int                 num_bytes;
    bit [7:0]           tx_bytes [];
    longint unsigned    timestamp_ns;
  } SpiHostSeg_s;

  typedef struct {
    longint unsigned    id;
    bit [7:0]           rx_bytes [];        // for RX_ONLY / BIDIR segments
    bit                 error;
    longint unsigned    timestamp_ns;
  } SpiHostRsp_s;

  // Per-byte wire activity for the bus monitor
  typedef struct {
    bit [7:0]           mosi_byte;
    bit [7:0]           miso_byte;
    int                 cs_index;
    longint unsigned    timestamp_ns;
  } SpiBusByte_s;

endpackage
