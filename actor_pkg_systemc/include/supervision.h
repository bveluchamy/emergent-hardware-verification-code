// supervision.h -- Erlang/OTP-style supervision for the SystemC actor port.
//
// Mirrors actor_supervision_pkg.sv (SystemVerilog side):
//
//   SystemC                                SystemVerilog
//   -------                                -------------
//   Strategy::ONE_FOR_ONE                  ONE_FOR_ONE
//   Strategy::ONE_FOR_ALL                  ONE_FOR_ALL
//   Strategy::REST_FOR_ONE                 REST_FOR_ONE
//
//   Directive::RESTART                     RESTART
//   Directive::STOP                        STOP
//   Directive::RESUME                      RESUME
//   Directive::ESCALATE                    ESCALATE
//
//   Supervisor                             Supervisor (Actor subclass)
//   DeathWatcher                           DeathWatcher
//   LinkRegistry                           LinkRegistry
//
// Behavioral differences from the SV port:
//
//   - "Restart" calls the child's reset() virtual method instead of
//     kill/spawn cycling the SC_THREAD. Subclasses override reset() to
//     reinitialize their state. The thread keeps running; the actor's
//     state is rolled back. This is simpler and avoids SC_THREAD
//     lifecycle complications.
//
//   - "Stop" sets is_alive = false. The run_loop drops out on the
//     next iteration. Restart re-enables is_alive and resets state.
//
//   - The restart budget (max_restarts in restart_window) is enforced
//     identically to the SV port; exceeding it is a fatal error.

#ifndef ACTOR_PKG_SYSTEMC_SUPERVISION_H
#define ACTOR_PKG_SYSTEMC_SUPERVISION_H

#include "actor.h"
#include <iostream>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace actor {
namespace supervision {

enum class Strategy {
  ONE_FOR_ONE,
  ONE_FOR_ALL,
  REST_FOR_ONE
};

enum class Directive {
  RESTART,    // child crashed but should restart
  STOP,       // child crashed and should stay dead
  RESUME,     // ignore failure, leave child running
  ESCALATE    // promote failure to my own supervisor
};

// First-class messages that any actor can observe.
struct ChildFailureMsg {
  uint32_t      child_id;
  std::string   child_name;
  std::string   reason;
  uint64_t      timestamp_ns;
};

struct DeathMsg {
  uint32_t      actor_id;
  std::string   actor_name;
  uint64_t      timestamp_ns;
};

// ---- Supervisor --------------------------------------------------------
// Wraps a set of child actors with a restart strategy. Subscribes to
// ChildFailureMsg via a standard wire<ChildFailureMsg>() edge (the children
// publish failures to their supervisor). On each failure, calls
// on_child_failure() to pick a directive and applies it to the children.
class Supervisor : public Actor {
 public:
  Supervisor(sc_module_name name,
             Strategy strategy = Strategy::ONE_FOR_ONE,
             int max_restarts = 10,
             sc_time restart_window = sc_time(60, SC_SEC))
      : Actor(name),
        strategy_(strategy),
        max_restarts_(max_restarts),
        window_(restart_window) {}

  void supervise(Actor* child) {
    children_.push_back(child);
  }

  // Override to choose per-failure directive (default: always RESTART).
  virtual Directive on_child_failure(uint32_t /*child_id*/,
                                     const std::string& /*reason*/) {
    return Directive::RESTART;
  }

  void act(std::shared_ptr<MsgBase> m) override {
    auto* f = dynamic_cast<Msg<ChildFailureMsg>*>(m.get());
    if (f == nullptr) return;
    Directive d = on_child_failure(f->payload.child_id, f->payload.reason);
    switch (d) {
      case Directive::RESTART:  do_restart(f->payload.child_id);  break;
      case Directive::STOP:     do_stop(f->payload.child_id);     break;
      case Directive::RESUME:                                     break;
      case Directive::ESCALATE: {
        // Forward up the supervisor chain, preserving lineage.
        auto out = make_traced_msg(f->payload, *m);
        publish(out);
        break;
      }
    }
  }

 private:
  std::vector<Actor*>            children_;
  Strategy                       strategy_;
  int                            max_restarts_;
  sc_time                        window_;
  std::map<uint32_t, int>        restart_count_;
  std::map<uint32_t, sc_time>    window_start_;

  void do_restart(uint32_t child_id) {
    Actor* c = find_child(child_id);
    if (c == nullptr) return;

    if (!enforce_budget(child_id)) {
      SC_REPORT_FATAL("supervisor",
        ("child " + c->actor_name + " exceeded restart budget").c_str());
    }

    auto restart_one = [](Actor* a) {
      a->is_alive.store(false);
      a->reset();                       // subclass-overridable hook
      a->is_alive.store(true);
    };

    switch (strategy_) {
      case Strategy::ONE_FOR_ONE:
        restart_one(c);
        break;
      case Strategy::ONE_FOR_ALL:
        for (auto* ch : children_) restart_one(ch);
        break;
      case Strategy::REST_FOR_ONE: {
        int idx = find_index(child_id);
        if (idx < 0) return;
        for (size_t i = static_cast<size_t>(idx); i < children_.size(); ++i) {
          restart_one(children_[i]);
        }
        break;
      }
    }
  }

  void do_stop(uint32_t child_id) {
    Actor* c = find_child(child_id);
    if (c != nullptr) c->stop();
  }

  bool enforce_budget(uint32_t child_id) {
    sc_time now = sc_time_stamp();
    auto it = window_start_.find(child_id);
    if (it == window_start_.end() || (now - it->second) > window_) {
      window_start_[child_id]  = now;
      restart_count_[child_id] = 0;
    }
    restart_count_[child_id]++;
    return restart_count_[child_id] <= max_restarts_;
  }

  Actor* find_child(uint32_t child_id) {
    for (auto* c : children_) {
      if (c->actor_id == child_id) return c;
    }
    return nullptr;
  }

  int find_index(uint32_t child_id) {
    for (size_t i = 0; i < children_.size(); ++i) {
      if (children_[i]->actor_id == child_id) return static_cast<int>(i);
    }
    return -1;
  }
};

// ---- DeathWatcher ------------------------------------------------------
// Erlang's `monitor`: one-way termination notification. Watcher actors
// register interest in target actors; when a target dies, every watcher
// receives a DeathMsg.
class DeathWatcher {
 public:
  void monitor(Actor* watcher, Actor* target) {
    watchers_by_target_[target->actor_id].push_back(watcher);
  }

  void notify_death(uint32_t target_id, const std::string& target_name) {
    auto it = watchers_by_target_.find(target_id);
    if (it == watchers_by_target_.end()) return;
    DeathMsg d{target_id, target_name,
               static_cast<uint64_t>(sc_time_stamp().to_seconds() * 1e9)};
    for (Actor* w : it->second) {
      w->mbox.nb_write(make_msg(d));
    }
  }

 private:
  std::map<uint32_t, std::vector<Actor*>> watchers_by_target_;
};

// ---- LinkRegistry ------------------------------------------------------
// Erlang's `link`: bidirectional fate sharing. If either actor in a link
// dies, the other receives a DeathMsg.
class LinkRegistry {
 public:
  void link(Actor* a, Actor* b) {
    linked_pairs_[a->actor_id].insert(b->actor_id);
    linked_pairs_[b->actor_id].insert(a->actor_id);
  }

  void on_death(Actor* dead, DeathWatcher& dw) {
    auto it = linked_pairs_.find(dead->actor_id);
    if (it == linked_pairs_.end()) return;
    for (uint32_t peer_id : it->second) {
      dw.notify_death(peer_id, dead->actor_name);
    }
  }

 private:
  std::map<uint32_t, std::set<uint32_t>> linked_pairs_;
};

}  // namespace supervision
}  // namespace actor

#endif  // ACTOR_PKG_SYSTEMC_SUPERVISION_H
