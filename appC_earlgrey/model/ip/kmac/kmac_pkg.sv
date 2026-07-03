// kmac_pkg.sv  --  Earlgrey KMAC (Keccak-MAC) messages.
package kmac_pkg;
  typedef struct {
    logic [255:0]    key;        // when MAC mode; '0 for hash-only mode
    bit [7:0]        msg [];     // arbitrary-length input
    int              digest_len; // bytes; typical 32 (256-bit)
    longint unsigned timestamp_ns;
  } KmacCmd_s;

  typedef struct {
    logic [511:0]    digest;     // up to 512-bit digest
    int              actual_len;
    bit              error;
    longint unsigned timestamp_ns;
  } KmacRsp_s;
endpackage
