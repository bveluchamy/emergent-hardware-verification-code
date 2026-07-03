#!/usr/bin/env python3
"""python_subscriber.py -- polyglot consumer of WorkerEvent messages.

Subscribes to the same ZMQ endpoint the C++/SystemC publisher binds to,
deserializes the same struct layout, and prints each event. Demonstrates
that the actor framework's distributed transport is language-agnostic
once the wire format is fixed.

Run alongside the publisher:
    ./build/publisher &
    python3 examples/distributed_demo/python_subscriber.py
"""
import struct
import sys
import time
import zmq

# struct layout: uint32 worker_id, uint32 seq, uint64 ts_ns, uint32 result
# Native alignment (matches the C++ struct's compiler-default layout):
# 4 + 4 + 8 + 4 = 20 bytes, padded to 24 for 8-byte struct alignment.
WORKER_EVENT_FMT = "@IIQI"
WORKER_EVENT_SIZE = 24


def main(endpoint: str = "tcp://localhost:5555", topic: bytes = b"worker_event"):
    ctx = zmq.Context.instance()
    sock = ctx.socket(zmq.SUB)
    sock.connect(endpoint)
    sock.setsockopt(zmq.SUBSCRIBE, topic)

    # Time-bounded run so the example exits cleanly.
    start = time.monotonic()
    deadline = start + 5.0
    print(f"[python_subscriber] listening on {endpoint} topic={topic!r}")
    poller = zmq.Poller()
    poller.register(sock, zmq.POLLIN)

    counts: dict[int, int] = {}
    while time.monotonic() < deadline:
        events = dict(poller.poll(timeout=200))
        if sock not in events:
            continue
        parts = sock.recv_multipart()
        if len(parts) != 2 or len(parts[1]) != WORKER_EVENT_SIZE:
            print(f"[python_subscriber] unexpected frame: parts={len(parts)}, "
                  f"sizes={[len(p) for p in parts]}")
            continue
        worker_id, seq, ts_ns, result = struct.unpack(WORKER_EVENT_FMT, parts[1][:20])
        counts[worker_id] = counts.get(worker_id, 0) + 1
        print(f"[python_subscriber] worker={worker_id} seq={seq} "
              f"ts_ns={ts_ns} result={result}")

    print("[python_subscriber] final counts:")
    for w, n in sorted(counts.items()):
        print(f"  worker {w} : {n} events")


if __name__ == "__main__":
    sys.exit(main())
