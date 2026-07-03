# ch2_rtl_fv_examples -- every Chapter 2 design proves from its BOOK FILES (the
# design .sv + its bound checker .sv, exactly as the book prints them) with the
# from-scratch Chapter 3 proof engines in ../ch3_fv_examples/01_proof_engines.
#
# Each design directory is SELF-CONTAINED: its own Makefile (make prove / bug /
# sim / traces -- see each) and its own README with instructions and expected
# output. This Makefile only recurses.
#
#   make check      prove every book contract, quiet (~7 min; mem_ctrl dominates)
#   make mutations  confirm the injected bug in every design is caught (~1 min)
#   make traces     regenerate the committed fv/ proof/refutation traces
#   make sim        run every Verilator testbench
#   make clean
#
# The full-geometry MSI CEGAR run (288 state bits -> 16 kept) is not part of
# `check` (~6 min): run `make -C 06_msi_cache full`.

DIRS := 01_soda_machine 02_arbiter 03_cdc_handshake 04_sync_fifo \
        05_pipelined_alu 06_msi_cache 07_mem_ctrl

.PHONY: all check mutations traces sim clean

all: check

check:
	@for d in $(DIRS); do \
	  echo "===== $$d ====="; \
	  $(MAKE) -s -C $$d check || exit 1; \
	done

mutations:
	@fail=0; \
	for d in $(DIRS); do $(MAKE) -s -C $$d mutation || fail=1; done; \
	exit $$fail

traces:
	@for d in $(DIRS); do $(MAKE) -s -C $$d traces; done

sim:
	@for d in $(DIRS); do \
	  echo "===== $$d ====="; \
	  $(MAKE) -s -C $$d sim || exit 1; \
	done

clean:
	@for d in $(DIRS); do $(MAKE) -s -C $$d clean; done
