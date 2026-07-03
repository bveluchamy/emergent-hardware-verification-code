// common.h -- shared message struct for the distributed demo.

#ifndef DISTRIBUTED_DEMO_COMMON_H
#define DISTRIBUTED_DEMO_COMMON_H

#include <cstdint>

struct WorkerEvent {
  uint32_t  worker_id;
  uint32_t  seq;
  uint64_t  timestamp_ns;
  uint32_t  result;
};

#endif
