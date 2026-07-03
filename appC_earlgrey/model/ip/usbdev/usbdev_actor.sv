// usbdev_actor.sv  --  Earlgrey USB device.
//
// Per-endpoint state machines respond to host packets. Each endpoint is
// modeled as a buffer pair (in/out) plus simple state tracking.

import actor_pkg::*;
import usbdev_pkg::*;
import irq_pkg::*;

class UsbDevActor extends Actor;
  // Endpoint config
  UsbEpConfig_s   ep_cfg [int];
  // Per-endpoint OUT buffer (host->device data the SW will read)
  bit [7:0]       ep_out_buf [int][$];
  // Per-endpoint IN buffer (data SW staged for the host to read)
  bit [7:0]       ep_in_buf  [int][$];
  // Stats
  int             in_count   [int];
  int             out_count  [int];
  bit             stalled    [int];

  function new(string name = "usbdev");
    super.new(name);
  endfunction

  function void stage_in_packet(int ep_num, bit [7:0] data []);
    foreach (data[i]) ep_in_buf[ep_num].push_back(data[i]);
  endfunction

  function void set_stall(int ep_num, bit s);
    stalled[ep_num] = s;
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(UsbEpConfig_s): begin
        UsbEpConfig_s c = Msg#(UsbEpConfig_s)::unwrap(msg);
        ep_cfg[c.ep_num] = c;
      end
      $typename(UsbHostPkt_s): begin
        UsbHostPkt_s h = Msg#(UsbHostPkt_s)::unwrap(msg);
        handle_host_packet(h);
      end
    endcase
  endtask

  task handle_host_packet(UsbHostPkt_s h);
    UsbDevicePkt_s rsp;
    UsbEpStats_s   stats;

    if (!ep_cfg.exists(h.ep_num)) begin
      send_pid(h.ep_num, USB_PID_STALL);
      return;
    end
    if (stalled[h.ep_num]) begin
      send_pid(h.ep_num, USB_PID_STALL);
      return;
    end

    case (h.pid)
      USB_PID_OUT, USB_PID_SETUP: begin
        if (!ep_cfg[h.ep_num].enable_out) begin send_pid(h.ep_num, USB_PID_NAK); return; end
        foreach (h.data[i]) ep_out_buf[h.ep_num].push_back(h.data[i]);
        out_count[h.ep_num]++;
        send_pid(h.ep_num, USB_PID_ACK);
        // Raise an interrupt for SW
        begin
          IrqMsg_s irq;
          irq.source_name    = name;
          irq.vector_id      = h.ep_num;
          irq.priority_level = 1;
          irq.timestamp_ns   = $time;
          `PUBLISH(irq);
        end
      end
      USB_PID_IN: begin
        if (!ep_cfg[h.ep_num].enable_in) begin send_pid(h.ep_num, USB_PID_NAK); return; end
        if (ep_in_buf[h.ep_num].size() == 0) begin send_pid(h.ep_num, USB_PID_NAK); return; end
        rsp.ep_num     = h.ep_num;
        rsp.pid        = USB_PID_DATA1;
        rsp.data       = new[ep_in_buf[h.ep_num].size()];
        for (int i = 0; rsp.data.size() > 0 && i < rsp.data.size(); i++)
          rsp.data[i]  = ep_in_buf[h.ep_num].pop_front();
        rsp.timestamp_ns = $time;
        `PUBLISH(rsp);
        in_count[h.ep_num]++;
      end
      default: ; // SOF, etc.
    endcase

    stats.ep_num            = h.ep_num;
    stats.in_packets_sent   = in_count [h.ep_num];
    stats.out_packets_recv  = out_count[h.ep_num];
    stats.stalled           = stalled  [h.ep_num];
    stats.timestamp_ns      = $time;
    `PUBLISH(stats);
  endtask

  function void send_pid(int ep_num, usb_pid_e pid);
    UsbDevicePkt_s rsp;
    rsp.ep_num       = ep_num;
    rsp.pid          = pid;
    rsp.data         = '{};
    rsp.timestamp_ns = $time;
    `PUBLISH(rsp);
  endfunction
endclass
