// actor_pkg_all.sv
//
// Umbrella include — pulls in the core actor_pkg and every parallel extension
// in one place. Use this when you want the full framework available; use the
// individual packages when you want only the substrate or only specific
// capabilities (the original 50-line core stands on its own).
//
// Typical user code:
//   `include "actor_pkg_all.sv"
//   import actor_pkg::*;
//   import actor_supervision_pkg::*;
//   import actor_routing_pkg::*;
//   ...
//
// The `include directives below assume all .sv files live in the same dir.
// Adjust the search path or use simulator -y / +incdir+ as appropriate.

`include "actor_pkg.sv"
`include "actor_supervision_pkg.sv"
`include "actor_routing_pkg.sv"
`include "actor_patterns_pkg.sv"
`include "actor_lifecycle_pkg.sv"
`include "actor_observability_pkg.sv"
`include "actor_verification_pkg.sv"
`include "actor_persistence_pkg.sv"
`include "actor_ral_pkg.sv"
`include "actor_distributed_pkg.sv"
`include "actor_test_pkg.sv"
