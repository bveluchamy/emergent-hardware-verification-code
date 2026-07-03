# Build and run all actor-sim prototype tests.
# Each test is self-checking and returns non-zero exit code on failure.

CXX      ?= c++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -O2 -I.

TESTS := test_mux2to1 \
         test_dff \
         test_counter \
         test_shiftreg \
         test_fsm_arbiter \
         test_alu \
         test_fifo

.PHONY: all test clean
all: test

%: %.cpp actor_sim.h
	$(CXX) $(CXXFLAGS) -o $@ $<

test: $(TESTS)
	@echo "================================================================"
	@echo "Running actor-sim prototype tests"
	@echo "================================================================"
	@fail=0; passed=0; total=0; \
	for t in $(TESTS); do \
	  echo ""; \
	  echo "--- $$t ---"; \
	  out=$$(./$$t) || fail=1; echo "$$out"; \
	  cc=$$(echo "$$out" | grep -oE '[0-9]+/[0-9]+ checks' | head -1 | sed 's/ checks//'); \
	  p=$${cc%%/*}; n=$${cc##*/}; passed=$$((passed + $${p:-0})); total=$$((total + $${n:-0})); \
	done; \
	echo ""; \
	echo "================================================================"; \
	if [ "$$fail" = "0" ]; then \
	  echo "ALL TESTS PASSED  ($$passed/$$total checks)"; \
	else \
	  echo "ONE OR MORE TESTS FAILED  ($$passed/$$total checks)"; \
	  exit 1; \
	fi

clean:
	rm -f $(TESTS)
