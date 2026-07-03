// vcd_writer.h -- minimal VCD (Value Change Dump) writer for actor_sim.
//
// VCD is the IEEE 1364 waveform format that GTKWave, ModelSim, and every
// other waveform viewer understand. Outputting VCD makes the actor-sim
// outputs debuggable with standard tooling and lets us cross-check against
// Verilator-generated waveforms cycle-by-cycle.
//
// Usage:
//
//   VcdWriter vcd("trace.vcd", "ns");
//   vcd.register_signal(clk_signal, "clk", "top");
//   vcd.register_signal(q_signal,   "q",   "top.dut");
//   vcd.write_header();
//   for (cycle = 0; ...) {
//       sim.tick();
//       vcd.dump(cycle * 10);    // 10 ns per cycle
//   }
//   vcd.close();
//
// The implementation tracks each signal's last-emitted value and only writes
// changes -- the "value change dump" semantic the format expects.

#ifndef ACTOR_PKG_CPP_SIM_VCD_WRITER_H
#define ACTOR_PKG_CPP_SIM_VCD_WRITER_H

#include "actor_sim.h"

#include <ctime>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace actor {
namespace sim {

class VcdWriter {
public:
    VcdWriter(std::string filename, std::string timescale = "1 ns")
        : filename_(std::move(filename)), timescale_(std::move(timescale)) {}

    // Register a signal under a hierarchical scope. The scope is
    // dot-separated ("top.dut.regs"); each component becomes a $scope in
    // the VCD header.
    template <int W>
    void register_signal(Signal<W>* sig, std::string name,
                        std::string scope = "top") {
        SigEntry e;
        e.scope = std::move(scope);
        e.name = std::move(name);
        e.width = W;
        e.last_binary = std::string(W, 'x');
        e.read_fn = [sig]() { return sig->read().to_binary(); };
        e.id = make_id_(entries_.size());
        entries_.push_back(std::move(e));
    }

    // Write the VCD preamble (date, scope tree, variable decls). Call once
    // before the first dump().
    void write_header() {
        out_.open(filename_);
        if (!out_) {
            throw std::runtime_error("VcdWriter: cannot open " + filename_);
        }
        std::time_t t = std::time(nullptr);
        char buf[64];
        std::strftime(buf, sizeof(buf), "%a %b %d %H:%M:%S %Y", std::localtime(&t));
        out_ << "$date " << buf << " $end\n";
        out_ << "$version actor_sim VCD writer 0.1 $end\n";
        out_ << "$timescale " << timescale_ << " $end\n";

        // Group entries by scope for $scope/$upscope blocks.
        // Scope strings are dot-delimited paths; emit a flat $scope per
        // unique path (simpler than building a tree for the prototype).
        std::set<std::string> scopes;
        for (auto& e : entries_) scopes.insert(e.scope);

        for (auto& scope : scopes) {
            out_ << "$scope module " << scope << " $end\n";
            for (auto& e : entries_) {
                if (e.scope == scope) {
                    out_ << "$var wire " << e.width << " " << e.id << " "
                         << e.name << " $end\n";
                }
            }
            out_ << "$upscope $end\n";
        }

        out_ << "$enddefinitions $end\n";

        // Initial values at time 0.
        out_ << "#0\n";
        out_ << "$dumpvars\n";
        for (auto& e : entries_) {
            std::string v = e.read_fn();
            emit_value_(out_, v, e.id, e.width);
            e.last_binary = v;
        }
        out_ << "$end\n";
    }

    // Emit a value-change dump at the given simulation time.
    void dump(uint64_t time) {
        bool wrote_time = false;
        for (auto& e : entries_) {
            std::string v = e.read_fn();
            if (v != e.last_binary) {
                if (!wrote_time) {
                    out_ << "#" << time << "\n";
                    wrote_time = true;
                }
                emit_value_(out_, v, e.id, e.width);
                e.last_binary = v;
            }
        }
    }

    void close() {
        if (out_.is_open()) out_.close();
    }

    ~VcdWriter() { close(); }

private:
    struct SigEntry {
        std::string scope;
        std::string name;
        int         width;
        std::string id;
        std::string last_binary;
        std::function<std::string()> read_fn;
    };

    static void emit_value_(std::ofstream& os, const std::string& binary,
                          const std::string& id, int width) {
        if (width == 1) {
            // Scalar: <value><id>
            os << binary << id << "\n";
        } else {
            // Vector: b<binary> <id>
            os << "b" << binary << " " << id << "\n";
        }
    }

    // Generate a short VCD identifier from an index (printable ASCII range
    // 33..126). Up to ~94^N unique IDs for N-char identifiers.
    static std::string make_id_(size_t idx) {
        std::string s;
        do {
            s.push_back(char(33 + (idx % 94)));
            idx /= 94;
        } while (idx > 0);
        return s;
    }

    std::string                  filename_;
    std::string                  timescale_;
    std::ofstream                out_;
    std::vector<SigEntry>        entries_;
};

}}  // namespace actor::sim

#endif  // ACTOR_PKG_CPP_SIM_VCD_WRITER_H
