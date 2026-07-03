// hmac_pkg.sv  --  Earlgrey HMAC (SHA-2 family) messages.
package hmac_pkg;
  typedef enum logic [1:0] {
    HMAC_MODE_SHA256 = 0,
    HMAC_MODE_SHA384 = 1,
    HMAC_MODE_SHA512 = 2
  } hmac_mode_e;

  typedef struct {
    hmac_mode_e      mode;
    bit              hmac_en;     // 0 = plain hash, 1 = HMAC w/ key
    logic [1023:0]   key;
    bit [7:0]        msg [];
    longint unsigned timestamp_ns;
  } HmacCmd_s;

  typedef struct {
    logic [511:0]    digest;
    longint unsigned timestamp_ns;
  } HmacRsp_s;
endpackage
