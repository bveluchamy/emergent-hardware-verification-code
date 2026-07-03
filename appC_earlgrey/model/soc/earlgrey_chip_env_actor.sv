// earlgrey_chip_env_actor.sv
//
// The Earlgrey chip-level environment as a single composed actor topology.
// In OpenTitan UVM, the equivalent (chip_env + chip_scoreboard +
// chip_virtual_sequencer + cip_base_env subset for chip-level) is
// roughly 1,500 lines of class hierarchy plus 40K of shared infrastructure.
//
// This env composes:
//   * 4 UART instances (Earlgrey has uart0..3)
//   * AON timer
//   * Alert handler (the existing AlertHandlerEnvActor without its sources --
//     we replace those with real-IP alert sources)
//   * pwrmgr / clkmgr / rstmgr / lc_ctrl  -- the power island
//   * flash_ctrl + rom_ctrl + otp_ctrl    -- non-volatile memories
//   * keymgr                              -- key derivation FSM
//   * AES, KMAC, HMAC                     -- crypto IPs
//   * entropy_src + csrng + edn0/edn1     -- RNG chain
//   * rv_core_ibex with lockstep pair + PLIC
//
// All composed via `WIRE edges; no class hierarchy.

import actor_pkg::*;
import actor_supervision_pkg::*;
import actor_observability_pkg::*;
import actor_persistence_pkg::*;
import actor_lifecycle_pkg::*;

import earlgrey_memory_map_pkg::*;
import tlul_pkg::*;
import alert_pkg::*;
import reset_pkg::*;
import irq_pkg::*;
import chip_msg_pkg::*;
import actor_ral_pkg::*;

// Auto-generated RAL definitions (one per Earlgrey IP)
import uart_ral_defs_pkg::*;
import gpio_ral_defs_pkg::*;
import i2c_ral_defs_pkg::*;
import spi_host_ral_defs_pkg::*;
import hmac_ral_defs_pkg::*;
import aes_ral_defs_pkg::*;
import kmac_ral_defs_pkg::*;
import aon_timer_ral_defs_pkg::*;
import csrng_ral_defs_pkg::*;
import edn_ral_defs_pkg::*;
import entropy_src_ral_defs_pkg::*;
import pwrmgr_ral_defs_pkg::*;
import rstmgr_ral_defs_pkg::*;
import clkmgr_ral_defs_pkg::*;
import lc_ctrl_ral_defs_pkg::*;
import flash_ctrl_ral_defs_pkg::*;
import rom_ctrl_ral_defs_pkg::*;
import otp_ctrl_ral_defs_pkg::*;
import keymgr_ral_defs_pkg::*;
import otbn_ral_defs_pkg::*;
import spi_device_ral_defs_pkg::*;
import usbdev_ral_defs_pkg::*;
import pwm_ral_defs_pkg::*;
import adc_ctrl_ral_defs_pkg::*;

import pwrmgr_pkg::*;
import clkmgr_pkg::*;
import rstmgr_pkg::*;
import lc_ctrl_pkg::*;
import flash_ctrl_pkg::*;
import rom_ctrl_pkg::*;
import otp_ctrl_pkg::*;
import keymgr_pkg::*;
import aes_pkg::*;
import kmac_pkg::*;
import hmac_pkg::*;
import entropy_src_pkg::*;
import csrng_pkg::*;
import edn_pkg::*;
import rv_plic_pkg::*;
import aon_timer_pkg::*;
import uart_pkg::*;
import gpio_pkg::*;
import pinmux_pkg::*;
import pwm_pkg::*;
import adc_ctrl_pkg::*;
import i2c_pkg::*;
import spi_host_pkg::*;
import spi_device_pkg::*;
import usbdev_pkg::*;
import otbn_pkg::*;

class EarlgreyChipEnvActor extends Actor;
  // ---- Per-IP environments and standalone IP actors ----
  // UART x4 (Earlgrey has uart0..uart3); we instantiate 2 with full envs
  // and stub the others as plain UartActors to keep the test concise.
  UartEnvActor               uart_envs [2];
  // AON timer (one)
  AonTimerEnvActor           aon_timer_env;
  // Alert handler (we replace its sources with real-IP alert sources)
  AlertHandlerEnvActor       alert_env;

  // ---- Power island ----
  PwrmgrActor                pwrmgr;
  ClkmgrActor                clkmgr;
  RstmgrActor                rstmgr;
  LcCtrlActor                lc_ctrl;

  // ---- Non-volatile memories ----
  FlashCtrlActor             flash_ctrl;
  RomCtrlActor               rom_ctrl;
  OtpCtrlActor               otp_ctrl;

  // ---- Key manager ----
  KeymgrActor                keymgr;

  // ---- Crypto ----
  AesActor                   aes;
  KmacActor                  kmac;
  HmacActor                  hmac;

  // ---- Entropy chain ----
  EntropySrcActor            entropy_src;
  CsrngActor                 csrng;
  EdnActor                   edn0;
  EdnActor                   edn1;

  // ---- CPU + interrupt controller ----
  RvPlicActor                plic;
  RvCoreIbexActor            ibex;

  // ---- Remaining Earlgrey IPs (the previously-omitted nine) ----
  GpioActor                  gpio;
  PinmuxActor                pinmux;
  PwmActor                   pwm;
  AdcCtrlActor               adc_ctrl;
  I2cActor                   i2c[3];
  SpiHostActor               spi_host[2];
  SpiDeviceActor             spi_device;
  UsbDevActor                usbdev;
  OtbnActor                  otbn;

  // ---- Bus + interconnect ----
  TlulXbarActor              xbar;
  TlulMonitorActor           xbar_mon;

  // ---- Chip-level scoreboard, observability ----
  ChipScoreboardActor        chip_scoreboard;
  TracerActor                chip_tracer;
  RecorderActor              chip_recorder;
  Supervisor                 chip_sup;

  // ---- Per-IP RAL actors. Each subscribes to xbar's TlulMonPkt_s
  //      and translates observed accesses in its own block to
  //      RalEvent_s. The chip scoreboard subscribes to every RAL.
  TlulRalActor               ral_uart0, ral_gpio, ral_i2c0, ral_spi_host0;
  TlulRalActor               ral_hmac, ral_aes, ral_kmac, ral_aon_timer;
  TlulRalActor               ral_csrng, ral_edn0, ral_edn1, ral_entropy_src;
  TlulRalActor               ral_pwrmgr, ral_rstmgr, ral_clkmgr, ral_lc_ctrl;
  TlulRalActor               ral_flash_ctrl, ral_rom_ctrl, ral_otp_ctrl;
  TlulRalActor               ral_keymgr, ral_otbn, ral_spi_device;
  TlulRalActor               ral_usbdev, ral_pwm, ral_adc_ctrl;

  function new(virtual interface tlul_if      tl_vif,
               virtual interface uart_if      uart0_vif,
               virtual interface uart_if      uart1_vif,
               virtual interface aon_timer_if aon_vif,
               string                         name = "EarlgreyChipEnvActor");
    UartConfig_s uart_cfg;
    super.new(name);

    // ---- UART envs (uart0 and uart1; uart2/uart3 omitted from the env for brevity) ----
    uart_cfg.baud_rate     = 1_000_000;
    uart_cfg.parity        = PARITY_NONE;
    uart_cfg.two_stop_bits = 0;
    uart_envs[0] = new(tl_vif, uart0_vif, uart_cfg, "uart0_env");
    uart_envs[1] = new(tl_vif, uart1_vif, uart_cfg, "uart1_env");

    // ---- Other per-IP envs ----
    aon_timer_env = new(aon_vif, "aon_timer_env");
    alert_env     = new("alert_env");

    // ---- Power island ----
    pwrmgr   = new("pwrmgr_aon");
    clkmgr   = new("clkmgr_aon");
    rstmgr   = new("rstmgr_aon");
    lc_ctrl  = new("lc_ctrl");

    // ---- Non-volatile memories ----
    flash_ctrl = new("flash_ctrl");
    rom_ctrl   = new("rom_ctrl");
    otp_ctrl   = new("otp_ctrl");

    // ---- Key manager ----
    keymgr  = new("keymgr");

    // ---- Crypto ----
    aes   = new("aes");
    kmac  = new("kmac");
    hmac  = new("hmac");

    // ---- Entropy chain ----
    entropy_src = new("entropy_src");
    csrng       = new("csrng");
    edn0        = new(0, "edn0");
    edn1        = new(1, "edn1");

    // ---- CPU + PLIC ----
    plic  = new("rv_plic");
    xbar  = new("main_xbar");
    xbar_mon = new(tl_vif, "xbar_monitor");
    ibex  = new(xbar, "rv_core_ibex");

    // ---- Remaining Earlgrey IPs ----
    gpio        = new("gpio");
    pinmux      = new("pinmux_aon");
    pwm         = new("pwm_aon");
    adc_ctrl    = new("adc_ctrl_aon");
    i2c[0]      = new("i2c0");
    i2c[1]      = new("i2c1");
    i2c[2]      = new("i2c2");
    spi_host[0] = new("spi_host0");
    spi_host[1] = new("spi_host1");
    spi_device  = new("spi_device");
    usbdev      = new("usbdev");
    otbn        = new("otbn");

    // ---- Chip-level verification stack ----
    chip_scoreboard = new("chip_scoreboard");
    chip_tracer     = new("chip_tracer");
    chip_recorder   = new("chip_recorder", "earlgrey_chip_trace.csv");

    // ---- Per-IP RAL actors. Each is constructed, told its block-base
    //      address, and populated by its auto-generated define_*_ral()
    //      function (one of the *_ral_defs.sv files imported above,
    //      regenerated by appC_earlgrey/tools/reggen_actor.py from the
    //      OpenTitan hjson register descriptions).
    ral_uart0       = new("ral.uart0");        ral_uart0.set_addr_offset(EG_UART0_BASE);          define_uart_ral(ral_uart0);
    ral_gpio        = new("ral.gpio");         ral_gpio.set_addr_offset(EG_GPIO_BASE);            define_gpio_ral(ral_gpio);
    ral_i2c0        = new("ral.i2c0");         ral_i2c0.set_addr_offset(EG_I2C0_BASE);            define_i2c_ral(ral_i2c0);
    ral_spi_host0   = new("ral.spi_host0");    ral_spi_host0.set_addr_offset(EG_SPI_HOST0_BASE);  define_spi_host_ral(ral_spi_host0);
    ral_hmac        = new("ral.hmac");         ral_hmac.set_addr_offset(EG_HMAC_BASE);            define_hmac_ral(ral_hmac);
    ral_aes         = new("ral.aes");          ral_aes.set_addr_offset(EG_AES_BASE);              define_aes_ral(ral_aes);
    ral_kmac        = new("ral.kmac");         ral_kmac.set_addr_offset(EG_KMAC_BASE);            define_kmac_ral(ral_kmac);
    ral_aon_timer   = new("ral.aon_timer");    ral_aon_timer.set_addr_offset(EG_AON_TIMER_AON_BASE); define_aon_timer_ral(ral_aon_timer);
    ral_csrng       = new("ral.csrng");        ral_csrng.set_addr_offset(EG_CSRNG_BASE);          define_csrng_ral(ral_csrng);
    ral_edn0        = new("ral.edn0");         ral_edn0.set_addr_offset(EG_EDN0_BASE);            define_edn_ral(ral_edn0);
    ral_edn1        = new("ral.edn1");         ral_edn1.set_addr_offset(EG_EDN1_BASE);            define_edn_ral(ral_edn1);
    ral_entropy_src = new("ral.entropy_src");  ral_entropy_src.set_addr_offset(EG_ENTROPY_SRC_BASE); define_entropy_src_ral(ral_entropy_src);
    ral_pwrmgr      = new("ral.pwrmgr");       ral_pwrmgr.set_addr_offset(EG_PWRMGR_AON_BASE);    define_pwrmgr_ral(ral_pwrmgr);
    ral_rstmgr      = new("ral.rstmgr");       ral_rstmgr.set_addr_offset(EG_RSTMGR_AON_BASE);    define_rstmgr_ral(ral_rstmgr);
    ral_clkmgr      = new("ral.clkmgr");       ral_clkmgr.set_addr_offset(EG_CLKMGR_AON_BASE);    define_clkmgr_ral(ral_clkmgr);
    ral_lc_ctrl     = new("ral.lc_ctrl");      ral_lc_ctrl.set_addr_offset(EG_LC_CTRL_BASE);      define_lc_ctrl_ral(ral_lc_ctrl);
    ral_flash_ctrl  = new("ral.flash_ctrl");   ral_flash_ctrl.set_addr_offset(EG_FLASH_CTRL_BASE);define_flash_ctrl_ral(ral_flash_ctrl);
    ral_rom_ctrl    = new("ral.rom_ctrl");     ral_rom_ctrl.set_addr_offset(EG_ROM_CTRL_BASE);    define_rom_ctrl_ral(ral_rom_ctrl);
    ral_otp_ctrl    = new("ral.otp_ctrl");     ral_otp_ctrl.set_addr_offset(EG_OTP_CTRL_BASE);    define_otp_ctrl_ral(ral_otp_ctrl);
    ral_keymgr      = new("ral.keymgr");       ral_keymgr.set_addr_offset(EG_KEYMGR_BASE);        define_keymgr_ral(ral_keymgr);
    ral_otbn        = new("ral.otbn");         ral_otbn.set_addr_offset(EG_OTBN_BASE);            define_otbn_ral(ral_otbn);
    ral_spi_device  = new("ral.spi_device");   ral_spi_device.set_addr_offset(EG_SPI_DEVICE_BASE);define_spi_device_ral(ral_spi_device);
    ral_usbdev      = new("ral.usbdev");       ral_usbdev.set_addr_offset(EG_USBDEV_BASE);        define_usbdev_ral(ral_usbdev);
    ral_pwm         = new("ral.pwm");          ral_pwm.set_addr_offset(EG_PWM_AON_BASE);          define_pwm_ral(ral_pwm);
    ral_adc_ctrl    = new("ral.adc_ctrl");     ral_adc_ctrl.set_addr_offset(EG_ADC_CTRL_AON_BASE);define_adc_ctrl_ral(ral_adc_ctrl);

    // ---- Wire address routing in the xbar (Earlgrey memory map) ----
    xbar.map_address(EG_UART0_BASE,        32'hFFFF_FF00, uart_envs[0].tl_slave);
    xbar.map_address(EG_UART1_BASE,        32'hFFFF_FF00, uart_envs[1].tl_slave);
    // ... real Earlgrey would map every IP. For demo, just two UARTs.

    // ---- Wire reset cascade ----
    // pwrmgr -> rstmgr -> ResetEvent_s broadcast -> all reset-aware actors
    `WIRE(pwrmgr, ClkGateReq_s, rstmgr)
    `WIRE(pwrmgr, PowerStateChange_s, rstmgr)
    `WIRE(pwrmgr, PwrStateTransition_s, rstmgr)
    `WIRE(aon_timer_env.timer, AonTimerEvent_s, rstmgr)
    `WIRE(aon_timer_env.timer, IrqMsg_s, rstmgr)
    `WIRE(aon_timer_env.timer, ResetReq_s, rstmgr)
    `WIRE(alert_env.reset_handler, EscActionResult_s, rstmgr)
    `WIRE(alert_env.reset_handler, ResetReq_s, rstmgr)
    `WIRE(alert_env.reset_handler, EscActionResult_s, chip_scoreboard)
    `WIRE(alert_env.reset_handler, ResetReq_s, chip_scoreboard)
    `WIRE(aon_timer_env.timer, AonTimerEvent_s, chip_scoreboard)
    `WIRE(aon_timer_env.timer, IrqMsg_s, chip_scoreboard)
    `WIRE(aon_timer_env.timer, ResetReq_s, chip_scoreboard)

    // rstmgr broadcasts ResetEvent_s to every reset-aware IP
    foreach (uart_envs[i]) `WIRE(rstmgr, ResetEvent_s, uart_envs[i].uart)
    `WIRE(rstmgr, ResetEvent_s, aon_timer_env.timer)
    `WIRE(rstmgr, ResetEvent_s, rom_ctrl)
    `WIRE(rstmgr, ResetEvent_s, otp_ctrl)
    `WIRE(rstmgr, ResetEvent_s, pwrmgr)
    `WIRE(rstmgr, ResetEvent_s, lc_ctrl)
    `WIRE(rstmgr, ResetEvent_s, ibex.core_a)
    `WIRE(rstmgr, ResetEvent_s, ibex.core_b)
    `WIRE(rstmgr, ResetEvent_s, chip_scoreboard)
    foreach (alert_env.handler.classes[i]) `WIRE(rstmgr, ResetEvent_s, alert_env.handler.classes[i])

    // ---- Wire alert sources -> alert_handler (replacing the synthetic sources) ----
    `WIRE(rom_ctrl, AlertEvent_s, alert_env.handler)
    `WIRE(rom_ctrl, RomHashCheck_s, alert_env.handler)
    `WIRE(entropy_src, AlertEvent_s, alert_env.handler)
    `WIRE(entropy_src, EntropyHealthAlert_s, alert_env.handler)
    `WIRE(entropy_src, EntropySeed_s, alert_env.handler)
    `WIRE(ibex.core_a, InstrTrace_s, alert_env.handler)
    `WIRE(ibex.core_a, PlicIrqClaim_s, alert_env.handler)
    `WIRE(ibex.core_a, PlicIrqComplete_s, alert_env.handler)
    `WIRE(ibex.core_b, InstrTrace_s, alert_env.handler)
    `WIRE(ibex.core_b, PlicIrqClaim_s, alert_env.handler)
    `WIRE(ibex.core_b, PlicIrqComplete_s, alert_env.handler)
    `WIRE(ibex.comparator, AlertEvent_s, alert_env.handler)
    `WIRE(ibex.comparator, LockstepMismatch_s, alert_env.handler)

    // alert escalation -> lc_ctrl and keymgr (forces SCRAP)
    foreach (alert_env.handler.classes[i]) begin
      `WIRE(alert_env.handler.classes[i], AlertEvent_s, lc_ctrl)
      `WIRE(alert_env.handler.classes[i], EscAction_s, lc_ctrl)
      `WIRE(alert_env.handler.classes[i], AlertEvent_s, keymgr)
      `WIRE(alert_env.handler.classes[i], EscAction_s, keymgr)
    end

    // ---- Wire clkmgr ----
    `WIRE(pwrmgr, ClkGateReq_s, clkmgr)
    `WIRE(pwrmgr, PowerStateChange_s, clkmgr)
    `WIRE(pwrmgr, PwrStateTransition_s, clkmgr)

    // ---- Wire entropy chain ----
    `WIRE(entropy_src, AlertEvent_s, csrng)
    `WIRE(entropy_src, EntropyHealthAlert_s, csrng)
    `WIRE(entropy_src, EntropySeed_s, csrng)
    `WIRE(csrng, CsrngRsp_s, edn0)
    `WIRE(csrng, CsrngRsp_s, edn1)
    `WIRE(edn0, CsrngCmd_s, csrng)
    `WIRE(edn0, EdnRsp_s, csrng)
    `WIRE(edn1, CsrngCmd_s, csrng)
    `WIRE(edn1, EdnRsp_s, csrng)

    // ---- Wire OTP -> downstream consumers ----
    `WIRE(otp_ctrl, OtpInitDone_s, keymgr)
    `WIRE(otp_ctrl, OtpRsp_s, keymgr)
    `WIRE(otp_ctrl, OtpInitDone_s, rom_ctrl)
    `WIRE(otp_ctrl, OtpRsp_s, rom_ctrl)
    `WIRE(otp_ctrl, OtpInitDone_s, lc_ctrl)
    `WIRE(otp_ctrl, OtpRsp_s, lc_ctrl)

    // ---- Wire IRQ aggregation ----
    `WIRE(aon_timer_env.timer, AonTimerEvent_s, plic)
    `WIRE(aon_timer_env.timer, IrqMsg_s, plic)
    `WIRE(aon_timer_env.timer, ResetReq_s, plic)
    foreach (i2c[i]) begin
      `WIRE(i2c[i], I2cBusEvent_s, plic)
      `WIRE(i2c[i], I2cTxnRsp_s, plic)
    end
    foreach (spi_host[i]) begin
      `WIRE(spi_host[i], SpiBusByte_s, plic)
      `WIRE(spi_host[i], SpiHostRsp_s, plic)
    end
    `WIRE(usbdev, IrqMsg_s, plic)
    `WIRE(usbdev, UsbDevicePkt_s, plic)
    `WIRE(usbdev, UsbEpStats_s, plic)
    `WIRE(gpio, GpioIntr_s, plic)
    `WIRE(gpio, GpioState_s, plic)
    `WIRE(gpio, IrqMsg_s, plic)
    `WIRE(otbn, EscAction_s, plic)
    `WIRE(otbn, IrqMsg_s, plic)
    `WIRE(otbn, OtbnExecDone_s, plic)
    `WIRE(otbn, OtbnMemReadRsp_s, plic)
    `WIRE(otbn, OtbnStateChange_s, plic)
    `WIRE(plic, PlicIrqClaim_s, ibex.core_a)

    // ---- Remaining IP fan-out for chip-level observation ----
    `WIRE(gpio, GpioIntr_s, chip_scoreboard)
    `WIRE(gpio, GpioState_s, chip_scoreboard)
    `WIRE(gpio, IrqMsg_s, chip_scoreboard)
    `WIRE(pinmux, PinmuxCfg_s, chip_scoreboard)
    `WIRE(pwm, PwmPulse_s, chip_scoreboard)
    `WIRE(adc_ctrl, AdcSampleEvent_s, chip_scoreboard)
    `WIRE(adc_ctrl, AdcWakeup_s, chip_scoreboard)
    foreach (i2c[i]) begin
      `WIRE(i2c[i], I2cBusEvent_s, chip_scoreboard)
      `WIRE(i2c[i], I2cTxnRsp_s, chip_scoreboard)
    end
    foreach (spi_host[i]) begin
      `WIRE(spi_host[i], SpiBusByte_s, chip_scoreboard)
      `WIRE(spi_host[i], SpiHostRsp_s, chip_scoreboard)
    end
    `WIRE(spi_device, SpiDeviceRsp_s, chip_scoreboard)
    `WIRE(usbdev, IrqMsg_s, chip_scoreboard)
    `WIRE(usbdev, UsbDevicePkt_s, chip_scoreboard)
    `WIRE(usbdev, UsbEpStats_s, chip_scoreboard)
    `WIRE(otbn, EscAction_s, chip_scoreboard)
    `WIRE(otbn, IrqMsg_s, chip_scoreboard)
    `WIRE(otbn, OtbnExecDone_s, chip_scoreboard)
    `WIRE(otbn, OtbnMemReadRsp_s, chip_scoreboard)
    `WIRE(otbn, OtbnStateChange_s, chip_scoreboard)
    `WIRE(otbn, EscAction_s, alert_env.handler)
    `WIRE(otbn, IrqMsg_s, alert_env.handler)
    `WIRE(otbn, OtbnExecDone_s, alert_env.handler)
    `WIRE(otbn, OtbnMemReadRsp_s, alert_env.handler)
    `WIRE(otbn, OtbnStateChange_s, alert_env.handler)
    `WIRE(adc_ctrl, AdcSampleEvent_s, pwrmgr)
    `WIRE(adc_ctrl, AdcWakeup_s, pwrmgr)

    // Reset cascade reaches the new IPs too
    `WIRE(rstmgr, ResetEvent_s, gpio)
    `WIRE(rstmgr, ResetEvent_s, pwm)
    `WIRE(rstmgr, ResetEvent_s, adc_ctrl)
    foreach (i2c[i])      `WIRE(rstmgr, ResetEvent_s, i2c[i])
    foreach (spi_host[i]) `WIRE(rstmgr, ResetEvent_s, spi_host[i])
    `WIRE(rstmgr, ResetEvent_s, spi_device)
    `WIRE(rstmgr, ResetEvent_s, usbdev)
    `WIRE(rstmgr, ResetEvent_s, otbn)

    // ---- Bus monitor -> chip scoreboard / tracer / recorder ----
    `WIRE(xbar_mon, TlulMonPkt_s, chip_scoreboard)
    `WIRE(xbar_mon, TlulMonPkt_s, chip_tracer)
    `WIRE(xbar_mon, TlulMonPkt_s, chip_recorder)
    // Also listen to xbar's synthetic TlulMonPkt_s (since the
    // testbench drives the bus through actor mailboxes, not pin
    // signals -- xbar_mon only sees the latter).
    `WIRE(xbar, TlulMonPkt_s, chip_scoreboard)
    `WIRE(xbar, TlulRsp_s, chip_scoreboard)
    `WIRE(xbar, TlulMonPkt_s, chip_tracer)
    `WIRE(xbar, TlulRsp_s, chip_tracer)
    `WIRE(xbar, TlulMonPkt_s, chip_recorder)
    `WIRE(xbar, TlulRsp_s, chip_recorder)

    // ---- Each per-IP RAL subscribes to xbar's synthetic TlulMonPkt_s
    //      stream. The RAL filters by its block-base offset and
    //      publishes a symbolic RalEvent_s when traffic falls in its
    //      address range. The chip scoreboard subscribes to every RAL
    //      to count register accesses by symbolic name.
    `WIRE(xbar, TlulMonPkt_s, ral_uart0)
    `WIRE(xbar, TlulRsp_s, ral_uart0)
    `WIRE(xbar, TlulMonPkt_s, ral_gpio)
    `WIRE(xbar, TlulRsp_s, ral_gpio)
    `WIRE(xbar, TlulMonPkt_s, ral_i2c0)
    `WIRE(xbar, TlulRsp_s, ral_i2c0)
    `WIRE(xbar, TlulMonPkt_s, ral_spi_host0)
    `WIRE(xbar, TlulRsp_s, ral_spi_host0)
    `WIRE(xbar, TlulMonPkt_s, ral_hmac)
    `WIRE(xbar, TlulRsp_s, ral_hmac)
    `WIRE(xbar, TlulMonPkt_s, ral_aes)
    `WIRE(xbar, TlulRsp_s, ral_aes)
    `WIRE(xbar, TlulMonPkt_s, ral_kmac)
    `WIRE(xbar, TlulRsp_s, ral_kmac)
    `WIRE(xbar, TlulMonPkt_s, ral_aon_timer)
    `WIRE(xbar, TlulRsp_s, ral_aon_timer)
    `WIRE(xbar, TlulMonPkt_s, ral_csrng)
    `WIRE(xbar, TlulRsp_s, ral_csrng)
    `WIRE(xbar, TlulMonPkt_s, ral_edn0)
    `WIRE(xbar, TlulRsp_s, ral_edn0)
    `WIRE(xbar, TlulMonPkt_s, ral_edn1)
    `WIRE(xbar, TlulRsp_s, ral_edn1)
    `WIRE(xbar, TlulMonPkt_s, ral_entropy_src)
    `WIRE(xbar, TlulRsp_s, ral_entropy_src)
    `WIRE(xbar, TlulMonPkt_s, ral_pwrmgr)
    `WIRE(xbar, TlulRsp_s, ral_pwrmgr)
    `WIRE(xbar, TlulMonPkt_s, ral_rstmgr)
    `WIRE(xbar, TlulRsp_s, ral_rstmgr)
    `WIRE(xbar, TlulMonPkt_s, ral_clkmgr)
    `WIRE(xbar, TlulRsp_s, ral_clkmgr)
    `WIRE(xbar, TlulMonPkt_s, ral_lc_ctrl)
    `WIRE(xbar, TlulRsp_s, ral_lc_ctrl)
    `WIRE(xbar, TlulMonPkt_s, ral_flash_ctrl)
    `WIRE(xbar, TlulRsp_s, ral_flash_ctrl)
    `WIRE(xbar, TlulMonPkt_s, ral_rom_ctrl)
    `WIRE(xbar, TlulRsp_s, ral_rom_ctrl)
    `WIRE(xbar, TlulMonPkt_s, ral_otp_ctrl)
    `WIRE(xbar, TlulRsp_s, ral_otp_ctrl)
    `WIRE(xbar, TlulMonPkt_s, ral_keymgr)
    `WIRE(xbar, TlulRsp_s, ral_keymgr)
    `WIRE(xbar, TlulMonPkt_s, ral_otbn)
    `WIRE(xbar, TlulRsp_s, ral_otbn)
    `WIRE(xbar, TlulMonPkt_s, ral_spi_device)
    `WIRE(xbar, TlulRsp_s, ral_spi_device)
    `WIRE(xbar, TlulMonPkt_s, ral_usbdev)
    `WIRE(xbar, TlulRsp_s, ral_usbdev)
    `WIRE(xbar, TlulMonPkt_s, ral_pwm)
    `WIRE(xbar, TlulRsp_s, ral_pwm)
    `WIRE(xbar, TlulMonPkt_s, ral_adc_ctrl)
    `WIRE(xbar, TlulRsp_s, ral_adc_ctrl)

    // ---- Per-IP RAL actors: bus traffic in, symbolic RalEvent_s out to scoreboard ----
    // Each RAL above resolves an observed TlulMonPkt_s into a symbolic
    // register access and publishes a RalEvent_s. The chip scoreboard
    // subscribes to every RAL so it can count CSR accesses by symbolic
    // name (ral_writes/ral_reads) instead of by raw address.
    `WIRE(ral_uart0, RalEvent_s, chip_scoreboard)
    `WIRE(ral_gpio, RalEvent_s, chip_scoreboard)
    `WIRE(ral_i2c0, RalEvent_s, chip_scoreboard)
    `WIRE(ral_spi_host0, RalEvent_s, chip_scoreboard)
    `WIRE(ral_hmac, RalEvent_s, chip_scoreboard)
    `WIRE(ral_aes, RalEvent_s, chip_scoreboard)
    `WIRE(ral_kmac, RalEvent_s, chip_scoreboard)
    `WIRE(ral_aon_timer, RalEvent_s, chip_scoreboard)
    `WIRE(ral_csrng, RalEvent_s, chip_scoreboard)
    `WIRE(ral_edn0, RalEvent_s, chip_scoreboard)
    `WIRE(ral_edn1, RalEvent_s, chip_scoreboard)
    `WIRE(ral_entropy_src, RalEvent_s, chip_scoreboard)
    `WIRE(ral_pwrmgr, RalEvent_s, chip_scoreboard)
    `WIRE(ral_rstmgr, RalEvent_s, chip_scoreboard)
    `WIRE(ral_clkmgr, RalEvent_s, chip_scoreboard)
    `WIRE(ral_lc_ctrl, RalEvent_s, chip_scoreboard)
    `WIRE(ral_flash_ctrl, RalEvent_s, chip_scoreboard)
    `WIRE(ral_rom_ctrl, RalEvent_s, chip_scoreboard)
    `WIRE(ral_otp_ctrl, RalEvent_s, chip_scoreboard)
    `WIRE(ral_keymgr, RalEvent_s, chip_scoreboard)
    `WIRE(ral_otbn, RalEvent_s, chip_scoreboard)
    `WIRE(ral_spi_device, RalEvent_s, chip_scoreboard)
    `WIRE(ral_usbdev, RalEvent_s, chip_scoreboard)
    `WIRE(ral_pwm, RalEvent_s, chip_scoreboard)
    `WIRE(ral_adc_ctrl, RalEvent_s, chip_scoreboard)

    foreach (uart_envs[i]) `WIRE(uart_envs[i].tl_monitor, TlulMonPkt_s, chip_scoreboard)

    // ---- Cross-IP events all flow into chip scoreboard ----
    `WIRE(aon_timer_env.timer, AonTimerEvent_s, chip_scoreboard)
    `WIRE(aon_timer_env.timer, IrqMsg_s, chip_scoreboard)
    `WIRE(aon_timer_env.timer, ResetReq_s, chip_scoreboard)
    foreach (alert_env.handler.classes[i]) begin
      `WIRE(alert_env.handler.classes[i], AlertEvent_s, chip_scoreboard)
      `WIRE(alert_env.handler.classes[i], EscAction_s, chip_scoreboard)
    end
    `WIRE(pwrmgr, ClkGateReq_s, chip_scoreboard)
    `WIRE(pwrmgr, PowerStateChange_s, chip_scoreboard)
    `WIRE(pwrmgr, PwrStateTransition_s, chip_scoreboard)
    `WIRE(rstmgr, ResetEvent_s, chip_scoreboard)
    `WIRE(lc_ctrl, LcTransitionResult_s, chip_scoreboard)
    `WIRE(lc_ctrl, LifecycleChange_s, chip_scoreboard)
    `WIRE(rom_ctrl, AlertEvent_s, chip_scoreboard)
    `WIRE(rom_ctrl, RomHashCheck_s, chip_scoreboard)
    `WIRE(keymgr, KeymgrAdvanceResult_s, chip_scoreboard)
    `WIRE(keymgr, KeymgrGenResult_s, chip_scoreboard)
    `WIRE(ibex.comparator, AlertEvent_s, chip_scoreboard)
    `WIRE(ibex.comparator, LockstepMismatch_s, chip_scoreboard)

    // ---- Ibex publishes through xbar ----
    `WIRE(ibex.core_a, InstrTrace_s, xbar)
    `WIRE(ibex.core_a, PlicIrqClaim_s, xbar)
    `WIRE(ibex.core_a, PlicIrqComplete_s, xbar)

    // ---- Chip-level supervision ----
    chip_sup = new("chip_sup", REST_FOR_ONE);
    chip_sup.max_restarts      = 100;
    chip_sup.restart_window_ns = 10_000_000_000;
    chip_sup.supervise(pwrmgr);
    chip_sup.supervise(clkmgr);
    chip_sup.supervise(rstmgr);
    chip_sup.supervise(lc_ctrl);
    chip_sup.supervise(flash_ctrl);
    chip_sup.supervise(rom_ctrl);
    chip_sup.supervise(otp_ctrl);
    chip_sup.supervise(keymgr);
    chip_sup.supervise(aes);
    chip_sup.supervise(kmac);
    chip_sup.supervise(hmac);
    chip_sup.supervise(entropy_src);
    chip_sup.supervise(csrng);
    chip_sup.supervise(edn0);
    chip_sup.supervise(edn1);
    chip_sup.supervise(plic);
    chip_sup.supervise(ibex.core_a);
    chip_sup.supervise(ibex.core_b);
    chip_sup.supervise(ibex.comparator);
    chip_sup.supervise(xbar);
    chip_sup.supervise(xbar_mon);
    chip_sup.supervise(chip_scoreboard);
    chip_sup.supervise(gpio);
    chip_sup.supervise(pinmux);
    chip_sup.supervise(pwm);
    chip_sup.supervise(adc_ctrl);
    foreach (i2c[i])       chip_sup.supervise(i2c[i]);
    foreach (spi_host[i])  chip_sup.supervise(spi_host[i]);
    chip_sup.supervise(spi_device);
    chip_sup.supervise(usbdev);
    chip_sup.supervise(otbn);

    // Per-IP RAL actors all run under the chip supervisor too, so
    // their mailbox-drain run() threads are spawned by start_all().
    chip_sup.supervise(ral_uart0);       chip_sup.supervise(ral_gpio);
    chip_sup.supervise(ral_i2c0);        chip_sup.supervise(ral_spi_host0);
    chip_sup.supervise(ral_hmac);        chip_sup.supervise(ral_aes);
    chip_sup.supervise(ral_kmac);        chip_sup.supervise(ral_aon_timer);
    chip_sup.supervise(ral_csrng);       chip_sup.supervise(ral_edn0);
    chip_sup.supervise(ral_edn1);        chip_sup.supervise(ral_entropy_src);
    chip_sup.supervise(ral_pwrmgr);      chip_sup.supervise(ral_rstmgr);
    chip_sup.supervise(ral_clkmgr);      chip_sup.supervise(ral_lc_ctrl);
    chip_sup.supervise(ral_flash_ctrl);  chip_sup.supervise(ral_rom_ctrl);
    chip_sup.supervise(ral_otp_ctrl);    chip_sup.supervise(ral_keymgr);
    chip_sup.supervise(ral_otbn);        chip_sup.supervise(ral_spi_device);
    chip_sup.supervise(ral_usbdev);      chip_sup.supervise(ral_pwm);
    chip_sup.supervise(ral_adc_ctrl);

    // ---- Registry: every named actor reachable by name ----
    ActorRegistry::register(pwrmgr);
    ActorRegistry::register(clkmgr);
    ActorRegistry::register(rstmgr);
    ActorRegistry::register(lc_ctrl);
    ActorRegistry::register(flash_ctrl);
    ActorRegistry::register(rom_ctrl);
    ActorRegistry::register(otp_ctrl);
    ActorRegistry::register(keymgr);
    ActorRegistry::register(aes);
    ActorRegistry::register(kmac);
    ActorRegistry::register(hmac);
    ActorRegistry::register(entropy_src);
    ActorRegistry::register(csrng);
    ActorRegistry::register(edn0);
    ActorRegistry::register(edn1);
    ActorRegistry::register(plic);
    ActorRegistry::register(ibex);
    ActorRegistry::register(gpio);
    ActorRegistry::register(pinmux);
    ActorRegistry::register(pwm);
    ActorRegistry::register(adc_ctrl);
    foreach (i2c[i])       ActorRegistry::register(i2c[i]);
    foreach (spi_host[i])  ActorRegistry::register(spi_host[i]);
    ActorRegistry::register(spi_device);
    ActorRegistry::register(usbdev);
    ActorRegistry::register(otbn);
  endfunction

  virtual function void start();
    foreach (uart_envs[i]) uart_envs[i].start();
    aon_timer_env.start();
    alert_env.start();
    chip_sup.start_all();
    chip_tracer.start();
    chip_recorder.start();
  endfunction

  function void report();
    $display("==== Earlgrey chip-level report ====");
    chip_scoreboard.report();
    ibex.report();
    chip_recorder.on_terminate();
    chip_tracer.export_jsonl("earlgrey_chip_trace.jsonl");
    $display("Per-IP summaries:");
    $display("  pwrmgr.state            = %s", pwrmgr.state.name());
    $display("  lc_ctrl.state           = %s", lc_ctrl.state.name());
    $display("  keymgr.state            = %s", keymgr.state.name());
    $display("  flash_ctrl ops          = R=%0d P=%0d E=%0d",
             flash_ctrl.ops_read, flash_ctrl.ops_prog, flash_ctrl.ops_erase);
    $display("  aes ops                 = %0d", aes.ops_done);
    $display("  kmac ops                = %0d", kmac.ops_done);
    $display("  hmac ops                = %0d", hmac.ops_done);
    $display("  entropy_src seeds       = %0d (health-fail=%0d)",
             entropy_src.seeds_emitted, entropy_src.health_failures);
    $display("  csrng ops               = %0d", csrng.ops_done);
    $display("  otbn programs/faults    = %0d / %0d", otbn.programs_run, otbn.faults_observed);
    $display("  pinmux routes config'd  = %0d", pinmux.routes_count());
    $display("  ActorRegistry size      = %0d", ActorRegistry::size());
    foreach (uart_envs[i]) uart_envs[i].report();
    aon_timer_env.report();
    alert_env.report();
  endfunction
endclass
