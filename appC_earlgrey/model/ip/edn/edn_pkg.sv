// edn_pkg.sv  --  Entropy Distribution Network messages.
//
// EDN packages CSRNG output and forwards it to a hardware consumer
// (AES, KMAC, OTBN, etc.) at request time. EDN0 typically feeds AES;
// EDN1 typically feeds KMAC/OTBN/keymgr.

package edn_pkg;
  typedef struct {
    int              consumer_id;     // which hardware EDN endpoint
    longint unsigned timestamp_ns;
  } EdnReq_s;

  typedef struct {
    int              consumer_id;
    logic [31:0]     bus_data [];     // packed random words
    longint unsigned timestamp_ns;
  } EdnRsp_s;
endpackage
