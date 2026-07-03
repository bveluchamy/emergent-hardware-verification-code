package ubus_pkg;

  // Transfer direction — matches UVM UBUS NOP/READ/WRITE
  typedef enum logic [1:0] { NOP=0, READ=1, WRITE=2 } ubus_dir_e;

  // Address map for 4 slaves — mirrors test_2m_4s address ranges
  // Slave 0: 0x0000-0x3FFF
  // Slave 1: 0x4000-0x7FFF
  // Slave 2: 0x8000-0xBFFF
  // Slave 3: 0xC000-0xFFFF
  typedef struct {
    logic [15:0] min_addr;
    logic [15:0] max_addr;
  } SlaveAddrMap_s;

  // Bus request from a Master Actor to the Master BFM Actor
  typedef struct {
    longint      id;
    int          master_id;
    logic [15:0] addr;
    ubus_dir_e   dir;
    logic  [7:0] data;
    int          size;
    int          transmit_delay;
  } UbusReq_s;

  // Bus response returned to the originating master after transfer completes
  typedef struct {
    longint      id;
    int          master_id;
    logic  [7:0] data;
    logic        error;
  } UbusRsp_s;

  // Scoreboard / coverage notification published by the bus monitor
  typedef struct {
    logic [15:0] addr;
    logic  [7:0] data;
    ubus_dir_e   dir;
    int          master_id;
  } UbusMonPkt_s;

endpackage
