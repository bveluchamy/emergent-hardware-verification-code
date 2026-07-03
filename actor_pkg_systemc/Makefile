# actor_pkg_systemc/Makefile -- build the SystemC actor framework examples.
#
# Requires SystemC 3.x (brew install systemc on macOS, or build from source).
# Set SYSTEMC_HOME if installed somewhere other than the homebrew path.

SYSTEMC_HOME ?= /usr/local/Cellar/systemc/3.0.2

CXX      ?= g++
CXXFLAGS  = -std=c++17 -Wall -Wextra -O2 \
            -I$(SYSTEMC_HOME)/include \
            -Iinclude
LDFLAGS   = -L$(SYSTEMC_HOME)/lib
LDLIBS    = -lsystemc

# DYLD_LIBRARY_PATH is needed at run-time on macOS for dylib resolution.
RUNENV    = DYLD_LIBRARY_PATH=$(SYSTEMC_HOME)/lib

EXAMPLES  = hello_actor supervision_demo

BUILD_DIR = build

.PHONY: all run clean

all: $(addprefix $(BUILD_DIR)/, $(EXAMPLES))

$(BUILD_DIR)/%: examples/%.cpp include/actor.h
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS) $(LDLIBS)

run: $(BUILD_DIR)/hello_actor
	$(RUNENV) ./$(BUILD_DIR)/hello_actor

run-supervision: $(BUILD_DIR)/supervision_demo
	$(RUNENV) ./$(BUILD_DIR)/supervision_demo

clean:
	rm -rf $(BUILD_DIR)
