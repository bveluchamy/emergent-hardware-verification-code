// zmq_bridge.h -- ZMQ pub/sub bridge actors for the SystemC port.
//
// Crosses process and machine boundaries with the same actor topology
// the rest of the framework uses. ZmqPublisherBridge serializes outbound
// messages to ZMQ; ZmqSubscriberBridge deserializes inbound messages and
// publishes them into the local actor topology, where any wired subscriber
// (scoreboard, coverage actor, recorder, etc.) consumes them as if the
// remote actor had published locally.
//
// The serialization protocol is a one-byte type tag followed by the
// raw struct bytes. Producers and consumers must agree on the type-tag
// table; the framework's typed message envelopes carry this tag in the
// MsgBase::type_name() return.

#ifndef ACTOR_PKG_SYSTEMC_ZMQ_BRIDGE_H
#define ACTOR_PKG_SYSTEMC_ZMQ_BRIDGE_H

#include "actor.h"
#include <zmq.hpp>
#include <atomic>
#include <chrono>
#include <cstring>
#include <functional>
#include <thread>

namespace actor {

// ZmqPublisherBridge: wire this actor (via wire<T>() from sources) into
// the local actor topology, and it forwards every received message out
// over a ZMQ PUB socket. Subscribers on the other side receive the same
// typed messages.
template <typename T>
class ZmqPublisherBridge : public Actor {
 public:
  ZmqPublisherBridge(sc_module_name name, const std::string& endpoint,
                     const std::string& topic = "")
      : Actor(name),
        ctx_(1),
        sock_(ctx_, zmq::socket_type::pub),
        topic_(topic) {
    sock_.bind(endpoint);
    // ZMQ slow-joiner: small wait so subscribers can connect.
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }

  void act(std::shared_ptr<MsgBase> m) override {
    auto* typed = dynamic_cast<Msg<T>*>(m.get());
    if (typed == nullptr) return;
    zmq::message_t topic_msg(topic_.data(), topic_.size());
    zmq::message_t payload_msg(&typed->payload, sizeof(T));
    sock_.send(topic_msg, zmq::send_flags::sndmore);
    sock_.send(payload_msg, zmq::send_flags::none);
  }

 private:
  zmq::context_t ctx_;
  zmq::socket_t  sock_;
  std::string    topic_;
};

// ZmqSubscriberBridge: connects to a ZMQ PUB endpoint, deserializes
// inbound messages, and publishes them into the local actor topology
// via this actor's wired subscribers. Use wire<T>() to connect a
// scoreboard / coverage actor / recorder downstream.
template <typename T>
class ZmqSubscriberBridge : public Actor {
 public:
  ZmqSubscriberBridge(sc_module_name name, const std::string& endpoint,
                      const std::string& topic = "")
      : Actor(name),
        ctx_(1),
        sock_(ctx_, zmq::socket_type::sub),
        running_(true) {
    sock_.connect(endpoint);
    sock_.set(zmq::sockopt::subscribe, topic);
    poll_thread_ = std::thread(&ZmqSubscriberBridge::poll_loop, this);
  }

  ~ZmqSubscriberBridge() {
    running_.store(false);
    if (poll_thread_.joinable()) poll_thread_.join();
  }

 private:
  void poll_loop() {
    while (running_.load()) {
      zmq::message_t topic_msg, payload_msg;
      auto r1 = sock_.recv(topic_msg, zmq::recv_flags::dontwait);
      if (!r1) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        continue;
      }
      auto r2 = sock_.recv(payload_msg, zmq::recv_flags::none);
      if (!r2 || payload_msg.size() != sizeof(T)) continue;
      T payload;
      std::memcpy(&payload, payload_msg.data(), sizeof(T));
      // Republish into the local topology so wired subscribers
      // see the message as if a local actor had published it.
      auto m = make_msg<T>(payload);
      stage_.lock();
      pending_.push_back(m);
      stage_.unlock();
    }
  }

 public:
  // Drain pending messages into local topology. Called from an SC_THREAD.
  void drain() {
    stage_.lock();
    auto local = std::move(pending_);
    pending_.clear();
    stage_.unlock();
    for (auto& m : local) publish(m);
  }

 private:
  zmq::context_t                            ctx_;
  zmq::socket_t                             sock_;
  std::atomic<bool>                         running_;
  std::thread                               poll_thread_;
  std::mutex                                stage_;
  std::vector<std::shared_ptr<MsgBase>>     pending_;
};

}  // namespace actor

#endif  // ACTOR_PKG_SYSTEMC_ZMQ_BRIDGE_H
