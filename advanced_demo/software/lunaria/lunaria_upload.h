#ifndef LUNARIA_UPLOAD_H
#define LUNARIA_UPLOAD_H
#include <stdint.h>
#define LN_UPLOAD_MAGIC UINT32_C(0x4c4e5531)
#define LN_UPLOAD_WORDS 1024u
#define LN_ASSET_WORDS 307200u
enum {
  LN_UPLOAD_BOOT = 0,
  LN_UPLOAD_WAIT = 1,
  LN_UPLOAD_PROCESS = 2,
  LN_UPLOAD_READY = 3,
  LN_UPLOAD_FAULT = 255
};
typedef struct {
  uint32_t magic, version, state, sequence, ack, window, offset, count,
      expected_hash, actual_hash, error;
  uint32_t received_background, received_atlas, background_hash, atlas_hash;
} ln_upload_t;
extern volatile ln_upload_t g_lunaria_upload;
extern volatile uint32_t g_lunaria_chunk[LN_UPLOAD_WORDS];
#endif
