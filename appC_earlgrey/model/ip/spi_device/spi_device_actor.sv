// spi_device_actor.sv  --  Earlgrey SPI device (slave).
import actor_pkg::*;
import spi_device_pkg::*;

class SpiDeviceActor extends Actor;
  SpiDeviceConfig_s   cfg;
  bit                 configured;
  // Flash backing store (for SPID_MODE_FLASH)
  bit [7:0]           flash [logic [23:0]];
  bit                 write_enabled;
  // TPM data FIFO
  bit [7:0]           tpm_fifo [$];

  function new(string name = "spi_device");
    super.new(name);
  endfunction

  function void load_flash_image(logic [23:0] base, bit [7:0] data []);
    foreach (data[i]) flash[base + i] = data[i];
  endfunction

  function void push_tpm_data(bit [7:0] data []);
    foreach (data[i]) tpm_fifo.push_back(data[i]);
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(SpiDeviceConfig_s): begin
        cfg = Msg#(SpiDeviceConfig_s)::unwrap(msg);
        configured = 1'b1;
      end
      $typename(SpiDeviceTxn_s): begin
        if (configured) begin
          SpiDeviceTxn_s txn = Msg#(SpiDeviceTxn_s)::unwrap(msg);
          handle_txn(txn);
        end
      end
    endcase
  endtask

  task handle_txn(SpiDeviceTxn_s txn);
    SpiDeviceRsp_s rsp;
    rsp.cmd_byte      = txn.cmd_byte;
    rsp.error         = 1'b0;
    rsp.timestamp_ns  = $time;

    case (cfg.mode)
      SPID_MODE_FLASH:    handle_flash(txn, rsp);
      SPID_MODE_TPM:      handle_tpm(txn, rsp);
      SPID_MODE_GENERIC:  handle_generic(txn, rsp);
    endcase

    `PUBLISH(rsp);
  endtask

  task handle_flash(SpiDeviceTxn_s txn, ref SpiDeviceRsp_s rsp);
    case (txn.cmd_byte)
      SPID_FLASH_READ_JEDEC_ID: begin
        rsp.response = '{8'hEF, 8'h40, 8'h18};     // mock JEDEC ID
      end
      SPID_FLASH_READ, SPID_FLASH_FAST_READ: begin
        // Address is in payload[0..2]
        logic [23:0] addr = {txn.payload[0], txn.payload[1], txn.payload[2]};
        rsp.response = new[txn.read_len];
        for (int i = 0; i < txn.read_len; i++)
          rsp.response[i] = flash.exists(addr + i) ? flash[addr + i] : 8'hFF;
      end
      SPID_FLASH_WRITE_ENABLE: begin
        write_enabled = 1'b1;
      end
      SPID_FLASH_PAGE_PROGRAM: begin
        if (!write_enabled) begin rsp.error = 1'b1; return; end
        begin
          logic [23:0] addr = {txn.payload[0], txn.payload[1], txn.payload[2]};
          for (int i = 3; i < txn.payload.size(); i++)
            flash[addr + i - 3] = txn.payload[i];
          write_enabled = 1'b0;
        end
      end
      SPID_FLASH_READ_STATUS_R1: begin
        rsp.response = '{8'h00};       // no busy, no errors
      end
      default: rsp.error = 1'b1;
    endcase
  endtask

  task handle_tpm(SpiDeviceTxn_s txn, ref SpiDeviceRsp_s rsp);
    if (txn.cmd_byte == SPID_TPM_DATA_FIFO) begin
      rsp.response = new[txn.read_len];
      for (int i = 0; i < txn.read_len; i++)
        rsp.response[i] = (tpm_fifo.size() > 0) ? tpm_fifo.pop_front() : 8'hFF;
    end
  endtask

  task handle_generic(SpiDeviceTxn_s txn, ref SpiDeviceRsp_s rsp);
    rsp.response = new[txn.read_len];
    for (int i = 0; i < txn.read_len; i++) rsp.response[i] = 8'hAA;     // stub
  endtask
endclass
