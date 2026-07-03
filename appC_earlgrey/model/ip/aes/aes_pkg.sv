// aes_pkg.sv  --  Earlgrey AES messages.

package aes_pkg;
  typedef enum logic [1:0] {
    AES_OP_ENCRYPT = 0,
    AES_OP_DECRYPT = 1
  } aes_op_e;

  typedef enum logic [1:0] {
    AES_MODE_ECB = 0,
    AES_MODE_CBC = 1,
    AES_MODE_CTR = 2,
    AES_MODE_GCM = 3
  } aes_mode_e;

  typedef struct {
    aes_op_e         op;
    aes_mode_e       mode;
    logic [255:0]    key;
    logic [127:0]    iv;
    logic [127:0]    plaintext;
    longint unsigned timestamp_ns;
  } AesCmd_s;

  typedef struct {
    aes_op_e         op;
    logic [127:0]    output_block;
    bit              error;
    longint unsigned timestamp_ns;
  } AesRsp_s;
endpackage
