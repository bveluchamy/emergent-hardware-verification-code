// i2c_actor.sv  --  Earlgrey I2C in host or target mode.
//
// Host mode: SW publishes I2cTxnReq_s; we run the transaction and
// publish I2cTxnRsp_s. We also publish per-byte I2cBusEvent_s for the
// monitor / scoreboard / coverage subscribers.
//
// Target mode: We respond to host transactions targeting our own
// 7-bit address with a configured response byte stream.

import actor_pkg::*;
import i2c_pkg::*;
import irq_pkg::*;

class I2cActor extends Actor;
  I2cConfig_s    cfg;
  bit            configured;
  // Target-mode response data the test pre-loads
  bit [7:0]      target_response_q [$];

  function new(string name = "i2c");
    super.new(name);
  endfunction

  function void load_target_response(bit [7:0] data []);
    target_response_q = {};
    foreach (data[i]) target_response_q.push_back(data[i]);
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(I2cConfig_s): begin
        cfg = Msg#(I2cConfig_s)::unwrap(msg);
        configured = 1'b1;
      end
      $typename(I2cTxnReq_s): begin
        if (configured && cfg.mode == I2C_HOST) begin
          I2cTxnReq_s req = Msg#(I2cTxnReq_s)::unwrap(msg);
          run_host_txn(req);
        end
      end
      $typename(I2cBusEvent_s): begin
        // Target-mode: react when a host issues an address that matches us
        if (configured && cfg.mode == I2C_TARGET) begin
          I2cBusEvent_s ev = Msg#(I2cBusEvent_s)::unwrap(msg);
          if (ev.kind == I2C_EV_ADDR && ev.target_addr == cfg.own_target_addr) begin
            target_respond();
          end
        end
      end
    endcase
  endtask

  task run_host_txn(I2cTxnReq_s req);
    I2cTxnRsp_s    rsp;
    I2cBusEvent_s  ev;
    int            byte_time_ns;

    byte_time_ns = (cfg.scl_freq_khz > 0) ? (1_000_000 / cfg.scl_freq_khz) * 9 : 1000;

    // START
    ev.kind          = I2C_EV_START;
    ev.timestamp_ns  = $time;
    `PUBLISH(ev);
    #(byte_time_ns / 9);

    // ADDR + R/W
    ev.kind          = I2C_EV_ADDR;
    ev.target_addr   = req.target_addr;
    ev.timestamp_ns  = $time;
    `PUBLISH(ev);
    #(byte_time_ns);

    rsp.id           = req.id;
    rsp.op           = req.op;
    rsp.acked        = 1'b1;     // assume ack in this behavioral model
    rsp.nack         = 1'b0;
    rsp.timeout      = 1'b0;

    if (req.op == I2C_OP_WRITE) begin
      foreach (req.tx_bytes[i]) begin
        ev.kind          = I2C_EV_BYTE_TX;
        ev.data          = req.tx_bytes[i];
        ev.timestamp_ns  = $time;
        `PUBLISH(ev);
        #(byte_time_ns);
      end
    end else begin // READ
      rsp.rx_bytes = new[req.read_len];
      for (int i = 0; i < req.read_len; i++) begin
        rsp.rx_bytes[i]  = $urandom & 8'hFF;
        ev.kind          = I2C_EV_BYTE_RX;
        ev.data          = rsp.rx_bytes[i];
        ev.timestamp_ns  = $time;
        `PUBLISH(ev);
        #(byte_time_ns);
      end
    end

    if (req.stop) begin
      ev.kind          = I2C_EV_STOP;
      ev.timestamp_ns  = $time;
      `PUBLISH(ev);
    end

    rsp.timestamp_ns = $time;
    `PUBLISH(rsp);
  endtask

  task target_respond();
    if (target_response_q.size() == 0) return;
    while (target_response_q.size() > 0) begin
      I2cBusEvent_s ev;
      ev.kind          = I2C_EV_BYTE_TX;
      ev.data          = target_response_q.pop_front();
      ev.timestamp_ns  = $time;
      `PUBLISH(ev);
      #500;
    end
  endtask
endclass
