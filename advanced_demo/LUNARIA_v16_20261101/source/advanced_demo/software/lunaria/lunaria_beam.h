#ifndef LUNARIA_BEAM_H
#define LUNARIA_BEAM_H
#include <stdint.h>
#define LN_OP_BEAM 4u
/* v13 opcode 4: src={signed ny,nx} in Q14, stride=signed distance at
 * rectangle origin. Color is ARGB. Same integer profile as FPGA beam_pixel. */
static inline uint32_t ln_beam_pixel(int32_t distance, uint32_t color) {
  uint32_t q = (uint32_t)(distance < 0 ? -distance : distance) >> 12;
  uint32_t a = 0, rgb = color & 0xffffffu;
  if ((color >> 24) < 128u) {
    if (q < 8u) a = 255u - q * 32u;
  } else if (q < 32u) {
    if (q < 8u) a = 255u;
    else if (q < 16u) a = 255u - (q - 8u) * 8u;
    else if (q < 24u) a = 191u - (q - 16u) * 16u;
    else a = 63u - (q - 24u) * 8u;
    if (q < 6u) rgb = 0xfff4ffu;
  }
  return (a << 24) | rgb;
}
#endif
