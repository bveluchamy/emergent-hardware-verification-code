# Top-level Makefile for the actor_pkg base framework (SystemVerilog packages).
#
#   make lint   - syntax-check every package with verilator --lint-only
#
# Examples and the C++/SystemC frameworks now live in their own top-level
# directories (ch<N>_* / app<X>_* / actor_pkg_cpp / actor_pkg_systemc), each
# building from its own dir. See CODE_MAP.md.

VERILATOR ?= verilator

# Core + every parallel extension. actor_distributed_pkg.sv lints OK in
# isolation (the DPI calls are extern declarations); linking it into a
# binary requires the matching C bindings (zmq, iceoryx, libfabric, nats).
PKG_SRCS = actor_pkg.sv \
           actor_supervision_pkg.sv \
           actor_routing_pkg.sv \
           actor_patterns_pkg.sv \
           actor_lifecycle_pkg.sv \
           actor_observability_pkg.sv \
           actor_verification_pkg.sv \
           actor_persistence_pkg.sv \
           actor_distributed_pkg.sv \
           actor_test_pkg.sv

# -Wno-ZERODLY: the framework's scheduling primitives (TimerActor, sample
# periods, ask/expect timeouts) use runtime-valued `#(expr * 1ns)` delays by
# design. Verilator cannot prove these are non-zero statically and warns they
# "can be #0"; a #0 would only be a benign delta cycle. The delays are
# intentional, so the warning is suppressed here rather than at every site.
lint:
	$(VERILATOR) --lint-only -sv -Wno-fatal -Wno-ZERODLY $(PKG_SRCS)

# Build and run the actor-based simulator prototype (Appendix I).
sim:
	$(MAKE) -C ../appI_actor_sim test

.PHONY: lint sim
