// usbdev_pkg.sv  --  Earlgrey USB 2.0 device.
package usbdev_pkg;

  parameter int unsigned EG_USB_NUM_EP = 12;       // Earlgrey has 12 endpoints

  typedef enum logic [3:0] {
    USB_EP_TYPE_CONTROL  = 0,
    USB_EP_TYPE_ISO      = 1,
    USB_EP_TYPE_BULK     = 2,
    USB_EP_TYPE_INTR     = 3
  } usb_ep_type_e;

  typedef enum logic [3:0] {
    USB_PID_OUT          = 4'h1,
    USB_PID_IN           = 4'h9,
    USB_PID_SOF          = 4'h5,
    USB_PID_SETUP        = 4'hD,
    USB_PID_DATA0        = 4'h3,
    USB_PID_DATA1        = 4'hB,
    USB_PID_ACK          = 4'h2,
    USB_PID_NAK          = 4'hA,
    USB_PID_STALL        = 4'hE
  } usb_pid_e;

  typedef struct {
    int                 ep_num;
    usb_ep_type_e       ep_type;
    int                 max_packet;
    bit                 enable_in;
    bit                 enable_out;
    longint unsigned    timestamp_ns;
  } UsbEpConfig_s;

  // External host sends a USB token+data packet
  typedef struct {
    int                 ep_num;
    usb_pid_e           pid;
    bit [7:0]           data [];
    longint unsigned    timestamp_ns;
  } UsbHostPkt_s;

  // Device responds to the host
  typedef struct {
    int                 ep_num;
    usb_pid_e           pid;
    bit [7:0]           data [];
    longint unsigned    timestamp_ns;
  } UsbDevicePkt_s;

  // Endpoint state observable for the scoreboard
  typedef struct {
    int                 ep_num;
    int                 in_packets_sent;
    int                 out_packets_recv;
    bit                 stalled;
    longint unsigned    timestamp_ns;
  } UsbEpStats_s;

endpackage
