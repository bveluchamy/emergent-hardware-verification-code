# actor_pkg_cpp/Makefile -- pure C++ actor framework, no SystemC dep.
#
# Two tiers:
#   actor.h         basic std::thread-per-actor actor framework
#   coro_actor.h    C++20 coroutine M:N green-thread actor framework
#
# Header-only library; examples link only against pthread.
# Build: make
# Run:   make run-pingpong       (coroutine ping-pong)
#        make run-pipeline       (coroutine pipeline)
#        make run-log            (basic-tier log pipeline)

CXX      ?= g++
CXXFLAGS  = -std=c++20 -Wall -Wextra -O2 -Iinclude
LDFLAGS   =
LDLIBS    = -lpthread

EXAMPLES  = log_pipeline coro_pingpong coro_pipeline

BUILD_DIR = build

.PHONY: all run-pingpong run-pipeline run-log clean

all: $(addprefix $(BUILD_DIR)/, $(EXAMPLES))

$(BUILD_DIR)/%: examples/%.cpp include/actor.h include/coro_actor.h
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS) $(LDLIBS)

run-pingpong: $(BUILD_DIR)/coro_pingpong
	./$(BUILD_DIR)/coro_pingpong

run-pipeline: $(BUILD_DIR)/coro_pipeline
	./$(BUILD_DIR)/coro_pipeline

run-log: $(BUILD_DIR)/log_pipeline
	./$(BUILD_DIR)/log_pipeline

clean:
	rm -rf $(BUILD_DIR)
