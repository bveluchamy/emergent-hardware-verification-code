// csrng_pkg.sv  --  Earlgrey CSRNG (SP800-90A AES-CTR DRBG).
package csrng_pkg;
  typedef enum logic [2:0] {
    CSRNG_INSTANTIATE = 0,
    CSRNG_RESEED      = 1,
    CSRNG_GENERATE    = 2,
    CSRNG_UPDATE      = 3,
    CSRNG_UNINSTANTIATE = 4
  } csrng_op_e;

  typedef struct {
    int              instance_id;     // 0,1 = EDN0/1; 2 = SW
    csrng_op_e       op;
    int              gen_len_words;   // for GENERATE
    longint unsigned timestamp_ns;
  } CsrngCmd_s;

  typedef struct {
    int              instance_id;
    csrng_op_e       op;
    logic [127:0]    rnd_word [];     // for GENERATE: requested random data
    bit              error;
    longint unsigned timestamp_ns;
  } CsrngRsp_s;

endpackage
