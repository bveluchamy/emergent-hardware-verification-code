// actor_distributed_pkg.sv
//
// Transport bridge templates — the distribution leg of Chapter 6. A bridge actor
// wraps a serialization + transport implementation behind the standard Actor
// interface, so distributing the topology across processes / machines becomes
// a per-stream choice rather than a global rewrite.
//
// Selection strategy (from the distribution analysis in Chapter 6):
//
//   inproc       SV mailbox        ~5 ns         existing actor_pkg core
//   intra-mach   Iceoryx zero-copy ~50 ns        kernel-bypass shared memory
//   inter-mach   libfabric / RDMA  ~700 ns       kernel-bypass IB / RoCE
//   ergonomic    ZeroMQ            ~1-10 us      easy default, polyglot
//   durable      NATS JetStream    ~1 ms         recorder/replay durability
//
// All four backends are sketched here as DPI-C wrappers. The C-side
// implementation files (zmq_dpi.c, iceoryx_dpi.cpp, libfabric_dpi.c,
// nats_dpi.c) are the user's to provide; they are not included.
// Compile only the bridge(s) you need and link the corresponding library.

package actor_distributed_pkg;
  import actor_pkg::*;

  typedef enum {
    TRANSPORT_INPROC,     // SV mailbox, same process
    TRANSPORT_ICEORYX,    // shared memory zero-copy
    TRANSPORT_LIBFABRIC,  // RDMA cross-machine
    TRANSPORT_ZMQ,        // ZeroMQ inproc/ipc/tcp
    TRANSPORT_NATS_JS     // NATS JetStream (durable)
  } TransportClass_e;

  // ---------------------------------------------------------------------------
  // DPI imports — the C side is provided by the user's chosen backend(s).
  // Each backend exposes init(endpoint, topic) + send(bytes) + recv(out_bytes).
  // ---------------------------------------------------------------------------
  import "DPI-C" function void zmq_dpi_init_pub      (string endpoint);
  import "DPI-C" function void zmq_dpi_pub_send      (string topic,
                                                       byte unsigned bytes[]);
  import "DPI-C" function void zmq_dpi_init_sub      (string endpoint, string topic);
  import "DPI-C" function int  zmq_dpi_sub_recv      (output byte unsigned bytes[]);

  import "DPI-C" function void iceoryx_dpi_init_pub  (string service, string instance_id);
  import "DPI-C" function void iceoryx_dpi_pub_send  (byte unsigned bytes[]);
  import "DPI-C" function void iceoryx_dpi_init_sub  (string service, string instance_id);
  import "DPI-C" function int  iceoryx_dpi_sub_recv  (output byte unsigned bytes[]);

  import "DPI-C" function void libfabric_dpi_init    (string provider, string node,
                                                       string svc);
  import "DPI-C" function void libfabric_dpi_send    (byte unsigned bytes[]);
  import "DPI-C" function int  libfabric_dpi_recv    (output byte unsigned bytes[]);

  import "DPI-C" function void nats_js_dpi_init      (string url, string subject);
  import "DPI-C" function void nats_js_dpi_publish   (byte unsigned bytes[]);
  import "DPI-C" function int  nats_js_dpi_subscribe (output byte unsigned bytes[]);

  // ---------------------------------------------------------------------------
  // TransportBridgeActor (abstract) — common shape for every backend.
  // Subclasses provide `serialize` / `deserialize` for their wire format.
  // ---------------------------------------------------------------------------
  virtual class TransportBridgeActor extends Actor;
    TransportClass_e  transport;
    string            endpoint;
    string            topic;
    int               batch_size = 1;       // amortize DPI cost
    MsgBase           outbox[$];

    function new(string name, TransportClass_e t,
                 string ep, string top);
      super.new(name);
      transport = t;
      endpoint  = ep;
      topic     = top;
    endfunction

    pure virtual function void send_bytes (byte unsigned bytes[]);
    pure virtual function int  recv_bytes (output byte unsigned bytes[]);

    // No default wire layout exists --- the concrete subclass picks it
    // (e.g. Cap'n Proto). An un-overridden serialize would silently send
    // zero-length frames, so fail loudly instead.
    virtual function void serialize(MsgBase msg, output byte unsigned bytes[]);
      bytes = new[0];
      $fatal(1, "%s: serialize() not overridden --- no default wire layout", name);
    endfunction

    virtual function MsgBase deserialize(byte unsigned bytes[]);
      return null;
    endfunction

    // Outbound side: wire this bridge to local actors via `WIRE for each
    // specific message type it can serialize.
    virtual task act(MsgBase msg);
      outbox.push_back(msg);
      if (outbox.size() >= batch_size) flush();
    endtask

    function void flush();
      foreach (outbox[i]) begin
        byte unsigned bytes[];
        serialize(outbox[i], bytes);
        send_bytes(bytes);
      end
      outbox.delete();
    endfunction

    // run() serves both directions. The base Actor loop is the ONLY caller
    // of act(), so replacing it outright would orphan the outbound side:
    // everything `WIRE'd to the bridge would queue in mbox forever. Fork the
    // inherited drain loop alongside the inbound transport poll.
    virtual task run();
      fork
        begin : outbound
          MsgBase mm;
          forever begin
            mbox.get(mm);
            act(mm);
          end
        end
        begin : inbound
          byte unsigned bytes[];
          MsgBase       m;
          forever begin
            int n = recv_bytes(bytes);
            if (n > 0) begin
              m = deserialize(bytes);
              if (m != null) publish(m);
            end else begin
              #1ns;   // backoff when empty
            end
          end
        end
      join
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Concrete bridges — minimal wiring of the DPI calls. Each lives behind the
  // same TransportBridgeActor surface so the rest of the topology is unaware
  // of which backend is in play.
  //
  // These four classes pass dynamic-array actuals (`byte unsigned bytes[]`) to
  // the DPI open-array formals above. That is legal IEEE-1800 DPI-C and is
  // accepted by VCS / Questa / Xcelium, but Verilator 5.x has not implemented
  // it (V3Task: "Passing dynamic array or queue as actual argument to DPI open
  // array is not yet supported"). Verilator auto-defines `VERILATOR`, so the
  // guard below hides only the concrete bridges from Verilator's lint pass
  // while real simulators still compile them. The abstract TransportBridgeActor
  // and the DPI import declarations stay visible to Verilator for syntax checks.
  // ---------------------------------------------------------------------------
`ifndef VERILATOR

  class ZmqBridgeActor extends TransportBridgeActor;
    function new(string name = "ZmqBridge", string ep = "tcp://*:5555",
                 string top = "actor.bus");
      super.new(name, TRANSPORT_ZMQ, ep, top);
      zmq_dpi_init_pub(ep);
      zmq_dpi_init_sub(ep, top);
    endfunction
    virtual function void send_bytes(byte unsigned bytes[]);
      zmq_dpi_pub_send(topic, bytes);
    endfunction
    virtual function int recv_bytes(output byte unsigned bytes[]);
      return zmq_dpi_sub_recv(bytes);
    endfunction
  endclass

  class IceoryxBridgeActor extends TransportBridgeActor;
    string service;
    string instance_name;
    function new(string name = "IceoryxBridge", string svc = "actor",
                 string inst = "bus");
      super.new(name, TRANSPORT_ICEORYX, svc, inst);
      service       = svc;
      instance_name = inst;
      iceoryx_dpi_init_pub(svc, inst);
      iceoryx_dpi_init_sub(svc, inst);
    endfunction
    virtual function void send_bytes(byte unsigned bytes[]);
      iceoryx_dpi_pub_send(bytes);
    endfunction
    virtual function int recv_bytes(output byte unsigned bytes[]);
      return iceoryx_dpi_sub_recv(bytes);
    endfunction
  endclass

  class LibfabricBridgeActor extends TransportBridgeActor;
    function new(string name = "LibfabricBridge", string provider = "verbs",
                 string node = "", string svc = "");
      super.new(name, TRANSPORT_LIBFABRIC, node, svc);
      libfabric_dpi_init(provider, node, svc);
    endfunction
    virtual function void send_bytes(byte unsigned bytes[]);
      libfabric_dpi_send(bytes);
    endfunction
    virtual function int recv_bytes(output byte unsigned bytes[]);
      return libfabric_dpi_recv(bytes);
    endfunction
  endclass

  class NatsJsBridgeActor extends TransportBridgeActor;
    function new(string name = "NatsJsBridge",
                 string url = "nats://localhost:4222",
                 string subject = "actor.bus");
      super.new(name, TRANSPORT_NATS_JS, url, subject);
      nats_js_dpi_init(url, subject);
    endfunction
    virtual function void send_bytes(byte unsigned bytes[]);
      nats_js_dpi_publish(bytes);
    endfunction
    virtual function int recv_bytes(output byte unsigned bytes[]);
      return nats_js_dpi_subscribe(bytes);
    endfunction
  endclass

`endif // VERILATOR

endpackage
