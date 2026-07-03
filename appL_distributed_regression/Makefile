# Distributed demo: publisher + subscriber + python observer.

SYSTEMC_HOME ?= /usr/local/Cellar/systemc/3.0.2
ZMQ_HOME     ?= /usr/local/Cellar/zeromq/4.3.5_2
CPPZMQ_HOME  ?= /usr/local/Cellar/cppzmq/4.11.0

CXX      ?= g++
CXXFLAGS  = -std=c++17 -Wall -Wextra -O2 \
            -I$(SYSTEMC_HOME)/include \
            -I$(ZMQ_HOME)/include \
            -I$(CPPZMQ_HOME)/include \
            -I../actor_pkg_systemc/include
LDFLAGS   = -L$(SYSTEMC_HOME)/lib -L$(ZMQ_HOME)/lib
LDLIBS    = -lsystemc -lzmq

RUNENV    = DYLD_LIBRARY_PATH=$(SYSTEMC_HOME)/lib:$(ZMQ_HOME)/lib

BUILD_DIR = build

.PHONY: all run-pub run-sub clean

all: $(BUILD_DIR)/publisher $(BUILD_DIR)/subscriber

$(BUILD_DIR)/%: %.cpp common.h ../actor_pkg_systemc/include/actor.h ../actor_pkg_systemc/include/zmq_bridge.h
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS) $(LDLIBS)

run-pub: $(BUILD_DIR)/publisher
	$(RUNENV) ./$(BUILD_DIR)/publisher

run-sub: $(BUILD_DIR)/subscriber
	$(RUNENV) ./$(BUILD_DIR)/subscriber

clean:
	rm -rf $(BUILD_DIR)
