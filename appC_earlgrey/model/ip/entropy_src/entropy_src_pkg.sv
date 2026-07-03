// entropy_src_pkg.sv  --  Earlgrey true random number source.
//
// entropy_src receives raw entropy from AST (analog noise sources) and
// runs SP800-90B health tests. Output is conditioned and forwarded to
// CSRNG.

package entropy_src_pkg;

  // Raw noise sample from AST
  typedef struct {
    logic [3:0]      raw_bits;
    longint unsigned timestamp_ns;
  } EntropyNoiseSample_s;

  // Conditioned entropy seed forwarded to CSRNG
  typedef struct {
    logic [383:0]    seed;        // 384-bit seed
    bit              fips_compliant;
    longint unsigned timestamp_ns;
  } EntropySeed_s;

  // Health test alert
  typedef struct {
    string           test_name;       // "repcnt", "adaptp", "bucket", etc.
    int              fail_count;
    longint unsigned timestamp_ns;
  } EntropyHealthAlert_s;

endpackage
