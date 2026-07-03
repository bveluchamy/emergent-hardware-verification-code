// earlgrey_chip_sw_test.sv
//
// A multi-scenario chip-level test mirroring the shape of OpenTitan's
// chip_sw_* sequence library:
//
//   1. Boot flow: rom_ctrl hash-checks the image, OTP publishes seeds,
//      keymgr advances RESET->INIT->CREATOR_ROOT_KEY->OWNER_INT_KEY, lc_ctrl
//      rejects the illegal volatile RAW->DEV request (stays RAW).
//   2. Background work: AES + KMAC + HMAC ops (driven by SW), each
//      consumes EDN entropy.
//   3. Lockstep glitch: inject a glitch on Ibex CoreA -- comparator
//      detects mismatch, raises alert, alert_handler escalates to
//      reset, full chip recovers.
//   4. Watchdog bite: AON timer's bite triggers system reset.
//
// In OpenTitan UVM each of these is a separate vseq (chip_sw_boot_flow,
// chip_sw_aes_*, chip_sw_rv_core_ibex_lockstep_glitch, chip_sw_aon_timer_*),
// each ~150-800 lines extending chip_sw_base_vseq (1,273 lines).

import actor_pkg::*;
import alert_pkg::*;
import lc_ctrl_pkg::*;
import otp_ctrl_pkg::*;
import keymgr_pkg::*;
import flash_ctrl_pkg::*;
import aes_pkg::*;
import kmac_pkg::*;
import hmac_pkg::*;
import csrng_pkg::*;
import edn_pkg::*;
import entropy_src_pkg::*;
import earlgrey_memory_map_pkg::*;
import pwrmgr_pkg::*;
import gpio_pkg::*;
import pinmux_pkg::*;
import pwm_pkg::*;
import adc_ctrl_pkg::*;
import i2c_pkg::*;
import spi_host_pkg::*;
import spi_device_pkg::*;
import usbdev_pkg::*;
import otbn_pkg::*;

class EarlgreyChipSwTest;
  EarlgreyChipEnvActor env;

  function new(EarlgreyChipEnvActor env);
    this.env = env;
  endfunction

  task run();
    env.start();

    // Pre-load deterministic seeds into OTP and a tiny ROM image
    seed_otp_and_rom();
    #100;

    boot_flow_phase();
    peripheral_traffic_phase();
    ral_csr_access_phase();
    background_crypto_phase();
    otbn_program_phase();
    lockstep_glitch_phase();
    watchdog_bite_phase();

    env.report();
  endtask

  // ----- Pre-test fixture loading -----
  function void seed_otp_and_rom();
    logic [31:0] rom_image [];
    logic [255:0] rom_hash;

    // Load a 16-word ROM image (acts as the boot ROM)
    rom_image = new[16];
    foreach (rom_image[i]) rom_image[i] = 32'hAA00_0000 | i;
    env.rom_ctrl.load_image(EG_ROM_MEM_BASE, rom_image);

    // Compute the matching hash (the same XOR-fold the actor does)
    rom_hash = '0;
    foreach (rom_image[i])
      rom_hash ^= rom_image[i] << ((i * 32) % 256);
    env.rom_ctrl.set_expected_hash(rom_hash);

    // Seed OTP with secrets and the ROM hash
    env.otp_ctrl.set_seeds(
      256'hCAFE_BABE_DEAD_BEEF_FEED_FACE_C0DE_F00D_F00D_FEED_CAFE_BABE_DEAD_BEEF_BAAD_F00D, // creator
      256'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210_0123_4567_89AB_CDEF_FEDC_BA98_7654_3210, // owner
      rom_hash,
      EG_LC_PROD
    );
  endfunction

  // ----- Phase 1: boot flow -----
  task boot_flow_phase();
    LcTransitionReq_s lc_req;
    KeymgrAdvanceReq_s adv;

    $display("\n[%0t] === Phase 1: BOOT FLOW ===", $time);

    // OTP publishes init done -> keymgr / rom_ctrl / lc_ctrl get seeds
    // (publish a fake reset deassert so the actors know to "boot")
    begin
      ResetEvent_s ev;
      ev.kind         = RST_CHIP;
      ev.asserted     = 1'b0;
      ev.timestamp_ns = $time;
      `PUBLISH_TO(env.otp_ctrl, ev);
      `PUBLISH_TO(env.rom_ctrl, ev);
    end
    #500;

    // keymgr advance x3: RESET -> INIT -> CREATOR_ROOT_KEY -> OWNER_INT_KEY
    adv.timestamp_ns = $time;
    `PUBLISH_TO(env.keymgr, adv);
    #50;
    `PUBLISH_TO(env.keymgr, adv);
    #50;
    `PUBLISH_TO(env.keymgr, adv);     // -> OWNER_INT_KEY
    #50;

    // lc_ctrl: request volatile RAW -> DEV (illegal hop; rejected, stays RAW)
    lc_req.kind          = LC_TX_VOLATILE;
    lc_req.target_state  = EG_LC_DEV;
    lc_req.token         = 128'hDEAD_BEEF_F00D_BAAD_F00D_BAAD_F00D_BAAD;
    lc_req.timestamp_ns  = $time;
    `PUBLISH_TO(env.lc_ctrl, lc_req);
    #100;

    $display("[%0t] Boot phase done. Ibex begins fetching...", $time);
    // Simulate the Ibex executing 16 instructions in lockstep
    for (int i = 0; i < 16; i++) begin
      env.ibex.step(EG_ROM_MEM_BASE + i * 4, 32'h0000_0013);     // nop
      #20;
    end
  endtask

  // ----- Phase 1.5: peripheral traffic on GPIO/PWM/ADC/I2C/SPI/USB/Pinmux -----
  task peripheral_traffic_phase();
    PinmuxCfg_s         px;
    GpioSetCmd_s        gset;
    GpioInputChange_s   gin;
    PwmConfig_s         pwm_cfg;
    AdcConfig_s         adc_cfg;
    AdcAnalogSample_s   adc_sample;
    I2cConfig_s         i2c_cfg;
    I2cTxnReq_s         i2c_req;
    SpiHostConfig_s     sph_cfg;
    SpiHostSeg_s        sph_seg;
    SpiDeviceConfig_s   spd_cfg;
    SpiDeviceTxn_s      spd_txn;
    UsbEpConfig_s       usb_ep;
    UsbHostPkt_s        usb_h;

    $display("\n[%0t] === Phase 1.5: PERIPHERAL TRAFFIC ===", $time);

    // Pinmux: route a few signals
    px.direction = PINMUX_OUT_DIRECTION;
    foreach (px.pad_index[i]) ;     // suppress lint
    for (int i = 0; i < 4; i++) begin
      px.pad_index   = i;
      px.signal_id   = 100 + i;
      px.timestamp_ns = $time;
      `PUBLISH_TO(env.pinmux, px);
    end

    // GPIO: enable IRQ on bottom 4 pins, drive an output, drive an input
    env.gpio.enable_intr(32'h0000_000F);
    gset.data        = 32'hAAAA_5555;
    gset.mask        = 32'h0000_FFFF;
    gset.timestamp_ns = $time;
    `PUBLISH_TO(env.gpio, gset);
    gin.pin           = 2;
    gin.value         = 1'b1;
    gin.timestamp_ns  = $time;
    `PUBLISH_TO(env.gpio, gin);

    // PWM: configure channel 0 with 50% duty
    pwm_cfg.channel       = 0;
    pwm_cfg.enable        = 1'b1;
    pwm_cfg.period_cycles = 100;
    pwm_cfg.duty_cycles   = 50;
    pwm_cfg.invert        = 1'b0;
    pwm_cfg.timestamp_ns  = $time;
    `PUBLISH_TO(env.pwm, pwm_cfg);

    // ADC: configure both channels and inject samples that trip both filters
    adc_cfg.mode             = ADC_MODE_NORMAL;
    foreach (adc_cfg.enable[i]) adc_cfg.enable[i] = 1'b1;
    adc_cfg.threshold_high[0] = 800;
    adc_cfg.threshold_low [0] = 200;
    adc_cfg.threshold_high[1] = 700;
    adc_cfg.threshold_low [1] = 300;
    adc_cfg.timestamp_ns      = $time;
    `PUBLISH_TO(env.adc_ctrl, adc_cfg);
    foreach (adc_cfg.enable[ch]) begin
      adc_sample.channel       = ch;
      adc_sample.sample_value  = 100;     // under low
      adc_sample.timestamp_ns  = $time;
      `PUBLISH_TO(env.adc_ctrl, adc_sample);
      adc_sample.sample_value  = 950;     // over high -> wakeup
      adc_sample.timestamp_ns  = $time;
      `PUBLISH_TO(env.adc_ctrl, adc_sample);
    end

    // I2C0 host mode: write 4 bytes to a target
    i2c_cfg.mode             = I2C_HOST;
    i2c_cfg.scl_freq_khz     = 400;
    i2c_cfg.own_target_addr  = 0;
    i2c_cfg.timestamp_ns     = $time;
    `PUBLISH_TO(env.i2c[0], i2c_cfg);
    i2c_req.id               = 1;
    i2c_req.op               = I2C_OP_WRITE;
    i2c_req.target_addr      = 7'h50;
    i2c_req.tx_bytes         = '{8'hDE, 8'hAD, 8'hBE, 8'hEF};
    i2c_req.read_len         = 0;
    i2c_req.stop             = 1'b1;
    i2c_req.timestamp_ns     = $time;
    `PUBLISH_TO(env.i2c[0], i2c_req);

    // SPI host: read JEDEC ID from a flash-mode SPI device
    sph_cfg.mode             = SPI_MODE_0;
    sph_cfg.sck_freq_mhz     = 25;
    sph_cfg.cs_index         = 0;
    sph_cfg.timestamp_ns     = $time;
    `PUBLISH_TO(env.spi_host[0], sph_cfg);

    spd_cfg.mode             = SPID_MODE_FLASH;
    spd_cfg.cpha_cpol        = 0;
    spd_cfg.timestamp_ns     = $time;
    `PUBLISH_TO(env.spi_device, spd_cfg);
    spd_txn.cmd_byte         = SPID_FLASH_READ_JEDEC_ID;
    spd_txn.payload          = '{};
    spd_txn.read_len         = 3;
    spd_txn.timestamp_ns     = $time;
    `PUBLISH_TO(env.spi_device, spd_txn);

    // SPI host issues a 4-byte TX segment + 4-byte RX segment
    sph_seg.kind             = SPI_SEG_TX_ONLY;
    sph_seg.num_bytes        = 4;
    sph_seg.tx_bytes         = '{8'h9F, 8'h00, 8'h00, 8'h00};
    sph_seg.timestamp_ns     = $time;
    `PUBLISH_TO(env.spi_host[0], sph_seg);
    sph_seg.kind             = SPI_SEG_RX_ONLY;
    sph_seg.num_bytes        = 4;
    sph_seg.timestamp_ns     = $time;
    `PUBLISH_TO(env.spi_host[0], sph_seg);

    // USB device: configure ep0 control, ep1 IN, ep2 OUT, then host sends
    // a SETUP, an IN, and an OUT.
    usb_ep.ep_num            = 0;
    usb_ep.ep_type           = USB_EP_TYPE_CONTROL;
    usb_ep.max_packet        = 64;
    usb_ep.enable_in         = 1'b1;
    usb_ep.enable_out        = 1'b1;
    usb_ep.timestamp_ns      = $time;
    `PUBLISH_TO(env.usbdev, usb_ep);
    usb_ep.ep_num            = 1;
    usb_ep.ep_type           = USB_EP_TYPE_BULK;
    `PUBLISH_TO(env.usbdev, usb_ep);
    usb_ep.ep_num            = 2;
    `PUBLISH_TO(env.usbdev, usb_ep);

    env.usbdev.stage_in_packet(1, '{8'h11, 8'h22, 8'h33, 8'h44});

    usb_h.ep_num             = 0;
    usb_h.pid                = USB_PID_SETUP;
    usb_h.data               = '{8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h12, 8'h00};
    usb_h.timestamp_ns       = $time;
    `PUBLISH_TO(env.usbdev, usb_h);

    usb_h.ep_num             = 1;
    usb_h.pid                = USB_PID_IN;
    usb_h.data               = '{};
    usb_h.timestamp_ns       = $time;
    `PUBLISH_TO(env.usbdev, usb_h);

    usb_h.ep_num             = 2;
    usb_h.pid                = USB_PID_OUT;
    usb_h.data               = '{8'hAA, 8'hBB, 8'hCC};
    usb_h.timestamp_ns       = $time;
    `PUBLISH_TO(env.usbdev, usb_h);

    #5_000;
  endtask

  // ----- Phase 1.7: CSR access through the RAL by symbolic name -----
  // This phase exercises the full bus->RAL->scoreboard observation path:
  //   * Test calls ibex.write_reg / read_reg with addresses resolved
  //     by the per-IP RalActor's addr_of(name).
  //   * Ibex publishes TlulReq_s to the xbar.
  //   * The xbar publishes a synthetic TlulMonPkt_s on forwarding.
  //   * Each per-IP RalActor (subscribing to xbar) sees the packet, and
  //     the matching block's RalActor publishes a RalEvent_s with the
  //     resolved register name.
  //   * The chip scoreboard subscribes to every RalActor and counts
  //     register accesses by symbolic name -- not by address.
  task ral_csr_access_phase();
    $display("\n[%0t] === Phase 1.7: RAL CSR ACCESS BY SYMBOLIC NAME ===", $time);

    // UART0: configure CTRL by name
    env.ibex.write_reg(env.ral_uart0.addr_of("CTRL"), 32'h0000_0003);
    #10;
    env.ibex.read_reg (env.ral_uart0.addr_of("STATUS"));
    #10;

    // I2C0: configure controller, write timing, read status
    env.ibex.write_reg(env.ral_i2c0.addr_of("CTRL"), 32'h0000_0001);
    #10;
    env.ibex.write_reg(env.ral_i2c0.addr_of("FIFO_CTRL"), 32'h0000_0080);
    #10;

    // SPI host: configure
    env.ibex.write_reg(env.ral_spi_host0.addr_of("CONTROL"), 32'h0000_0001);
    #10;

    // GPIO: drive masked write, read input
    env.ibex.write_reg(env.ral_gpio.addr_of("DIRECT_OUT"), 32'h0000_FFFF);
    #10;
    env.ibex.read_reg (env.ral_gpio.addr_of("DATA_IN"));
    #10;

    // AES, KMAC, HMAC: trigger commands by name
    env.ibex.write_reg(env.ral_aes.addr_of("TRIGGER"), 32'h0000_0001);
    #10;
    env.ibex.write_reg(env.ral_kmac.addr_of("CMD"),    32'h0000_0001);
    #10;
    env.ibex.write_reg(env.ral_hmac.addr_of("CMD"),    32'h0000_0001);
    #10;

    // Pwrmgr / lc_ctrl / keymgr: configuration registers
    env.ibex.write_reg(env.ral_pwrmgr.addr_of("CTRL_CFG_REGWEN"), 32'h0000_0001);
    #10;
    env.ibex.read_reg (env.ral_lc_ctrl.addr_of("STATUS"));
    #10;
    env.ibex.read_reg (env.ral_keymgr.addr_of("OP_STATUS"));
    #10;

    // Entropy + RNG chain: command + observe
    env.ibex.write_reg(env.ral_entropy_src.addr_of("MODULE_ENABLE"), 32'h0000_0009);
    #10;
    env.ibex.write_reg(env.ral_csrng.addr_of("CTRL"), 32'h0000_0001);
    #10;

    // OTBN, flash_ctrl, rom_ctrl, otp_ctrl
    env.ibex.write_reg(env.ral_otbn.addr_of("CMD"), 32'h0000_0001);
    #10;
    env.ibex.read_reg (env.ral_flash_ctrl.addr_of("STATUS"));
    #10;
    env.ibex.read_reg (env.ral_rom_ctrl.addr_of("FATAL_ALERT_CAUSE"));
    #10;
    env.ibex.read_reg (env.ral_otp_ctrl.addr_of("STATUS"));
    #10;

    // Allow the xbar to forward and the RAL chain to publish events
    #2_000;
  endtask

  // ----- Phase 2: background crypto + entropy -----
  task background_crypto_phase();
    AesCmd_s             aes_cmd;
    KmacCmd_s            kmac_cmd;
    HmacCmd_s            hmac_cmd;
    EntropyNoiseSample_s ns;
    CsrngCmd_s           csrng_inst;
    EdnReq_s             edn_req;
    KeymgrGenReq_s       gen;

    $display("\n[%0t] === Phase 2: CRYPTO + ENTROPY ===", $time);

    // Feed entropy_src enough noise samples to emit 1 seed (96 4-bit samples = 384 bits)
    for (int i = 0; i < 100; i++) begin
      ns.raw_bits      = $urandom & 4'hF;
      ns.timestamp_ns  = $time;
      `PUBLISH_TO(env.entropy_src, ns);
    end
    #200;

    // CSRNG instantiate using the fresh seed
    csrng_inst.instance_id    = 0;
    csrng_inst.op             = CSRNG_INSTANTIATE;
    csrng_inst.timestamp_ns   = $time;
    `PUBLISH_TO(env.csrng, csrng_inst);
    #50;

    // EDN0 request -> CSRNG generate -> back to EDN0 -> consumer
    edn_req.consumer_id      = 100;     // arbitrary AES endpoint id
    edn_req.timestamp_ns     = $time;
    `PUBLISH_TO(env.edn0, edn_req);
    #200;

    // Issue a few AES, KMAC, HMAC ops
    aes_cmd.op           = AES_OP_ENCRYPT;
    aes_cmd.mode         = AES_MODE_ECB;
    aes_cmd.key          = 256'hFEED_FACE_DEAD_BEEF_BAAD_F00D_FEED_FACE_DEAD_BEEF_BAAD_F00D_FEED_FACE_DEAD_BEEF;
    aes_cmd.iv           = '0;
    aes_cmd.plaintext    = 128'h1234_5678_9ABC_DEF0_1122_3344_5566_7788;
    aes_cmd.timestamp_ns = $time;
    `PUBLISH_TO(env.aes, aes_cmd);

    kmac_cmd.key         = 256'hCAFE_BABE_DEAD_BEEF_FEED_FACE_C0DE_F00D_C0DE_F00D_FEED_FACE_DEAD_BEEF_BAAD_F00D;
    kmac_cmd.msg         = '{8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46, 8'h47, 8'h48};
    kmac_cmd.digest_len  = 32;
    kmac_cmd.timestamp_ns = $time;
    `PUBLISH_TO(env.kmac, kmac_cmd);

    hmac_cmd.mode        = HMAC_MODE_SHA256;
    hmac_cmd.hmac_en     = 1'b1;
    hmac_cmd.key         = 1024'h0;
    hmac_cmd.key[127:0]  = 128'hDEAD_BEEF_FEED_FACE_DEAD_BEEF_FEED_FACE;
    hmac_cmd.msg         = '{8'h61, 8'h62, 8'h63};
    hmac_cmd.timestamp_ns = $time;
    `PUBLISH_TO(env.hmac, hmac_cmd);

    // keymgr generate output for a downstream consumer
    gen.dest          = "aes";
    gen.salt          = 256'hCAFE_BABE_DEAD_BEEF_FEED_FACE_C0DE_F00D_C0DE_F00D_FEED_FACE_DEAD_BEEF_BAAD_F00D;
    gen.timestamp_ns  = $time;
    `PUBLISH_TO(env.keymgr, gen);

    #2000;
  endtask

  // ----- Phase 2.5: OTBN program execution -----
  task otbn_program_phase();
    OtbnMemWrite_s   wr;
    OtbnExecReq_s    req;

    $display("\n[%0t] === Phase 2.5: OTBN PROGRAM ===", $time);

    // Load a tiny "program" (8 instruction words; behavioral execution
    // doesn't interpret RV32I, just simulates timing)
    for (int i = 0; i < 8; i++) begin
      wr.region        = OTBN_REGION_IMEM;
      wr.word_offset   = i;
      wr.data          = 32'h0000_0013 + i;     // marker pattern
      wr.timestamp_ns  = $time;
      `PUBLISH_TO(env.otbn, wr);
    end

    // Kick off execution
    req.start_pc       = 0;
    req.timestamp_ns   = $time;
    `PUBLISH_TO(env.otbn, req);
    #1_500;
  endtask

  // ----- Phase 3: lockstep glitch -----
  task lockstep_glitch_phase();
    $display("\n[%0t] === Phase 3: LOCKSTEP GLITCH ===", $time);

    // Run a few clean lockstep steps first
    for (int i = 0; i < 4; i++) begin
      env.ibex.step(32'h0000_8400 + i * 4, 32'h0000_0013);
      #20;
    end

    // Inject a glitch on CoreA: next PC will be XORed
    $display("[%0t] Injecting glitch on Ibex CoreA...", $time);
    env.ibex.inject_glitch(32'h0000_0010);
    env.ibex.step(32'h0000_8420, 32'h0000_0013);
    #500;     // let comparator detect, alert escalate, reset propagate
    env.ibex.inject_glitch(32'h0);
  endtask

  // ----- Phase 4: watchdog bite -----
  task watchdog_bite_phase();
    AonTimerConfig_s ac;
    $display("\n[%0t] === Phase 4: WATCHDOG BITE ===", $time);
    ac.prescaler        = 0;
    ac.wkup_threshold   = 1_000_000;     // never fires in this test
    ac.bark_threshold   = 50;
    ac.bite_threshold   = 100;
    ac.wkup_enable      = 0;
    ac.wdog_enable      = 1;
    ac.pause_in_sleep   = 0;
    `PUBLISH_TO(env.aon_timer_env.timer, ac);
    // 100 ticks * 5us = 500 us; allow a little extra
    #800_000;
  endtask
endclass
