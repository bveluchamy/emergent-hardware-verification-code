// spi_host_actor.sv  --  Earlgrey SPI host controller.
//
// SW publishes a sequence of SpiHostSeg_s structs (one per segment of
// a transaction). The host actor runs them in order, publishing per-byte
// SpiBusByte_s events the bus monitor / scoreboard can subscribe to,
// and a final SpiHostRsp_s when done.

import actor_pkg::*;
import spi_host_pkg::*;

class SpiHostActor extends Actor;
  SpiHostConfig_s    cfg;
  bit                configured;
  SpiHostSeg_s       seg_q [$];
  // Last consumed RX bytes (to coalesce into one rsp)
  bit [7:0]          rx_collected [$];
  longint unsigned   txn_id_counter;

  function new(string name = "spi_host");
    super.new(name);
  endfunction

  virtual task act(MsgBase msg);
    case (msg.getTypeName())
      $typename(SpiHostConfig_s): begin
        cfg = Msg#(SpiHostConfig_s)::unwrap(msg);
        configured = 1'b1;
      end
      $typename(SpiHostSeg_s): begin
        SpiHostSeg_s seg = Msg#(SpiHostSeg_s)::unwrap(msg);
        run_segment(seg);
      end
    endcase
  endtask

  task run_segment(SpiHostSeg_s seg);
    SpiHostRsp_s     rsp;
    SpiBusByte_s     bb;
    int              byte_time_ns = (cfg.sck_freq_mhz > 0)
                                  ? (1000 / cfg.sck_freq_mhz) * 8 : 1000;

    for (int i = 0; i < seg.num_bytes; i++) begin
      bb.cs_index       = cfg.cs_index;
      bb.mosi_byte      = (seg.kind == SPI_SEG_TX_ONLY || seg.kind == SPI_SEG_BIDIR)
                          ? seg.tx_bytes[i] : 8'h00;
      bb.miso_byte      = (seg.kind == SPI_SEG_RX_ONLY || seg.kind == SPI_SEG_BIDIR)
                          ? ($urandom & 8'hFF) : 8'h00;
      bb.timestamp_ns   = $time;
      `PUBLISH(bb);
      if (seg.kind == SPI_SEG_RX_ONLY || seg.kind == SPI_SEG_BIDIR)
        rx_collected.push_back(bb.miso_byte);
      #(byte_time_ns);
    end

    // After last segment, return collected RX
    if (seg.kind == SPI_SEG_RX_ONLY || seg.kind == SPI_SEG_BIDIR) begin
      rsp.id = ++txn_id_counter;
      rsp.rx_bytes = new[rx_collected.size()];
      for (int i = 0; i < rx_collected.size(); i++) rsp.rx_bytes[i] = rx_collected[i];
      rsp.error         = 1'b0;
      rsp.timestamp_ns  = $time;
      `PUBLISH(rsp);
      rx_collected = {};
    end
  endtask
endclass
