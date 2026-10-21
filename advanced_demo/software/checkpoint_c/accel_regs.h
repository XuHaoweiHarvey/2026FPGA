#ifndef ACCEL_REGS_H
#define ACCEL_REGS_H
#include <stdint.h>
#include "soc.h" /* Formal generated BSP; no Demo 08 address fallback. */
#ifndef IO_APB_SLAVE_0_INPUT
#error "Generate the formal Sapphire with APB3 Slave 0 enabled first"
#endif
#ifndef IO_APB_SLAVE_0_INPUT_SIZE
#error "Formal soc.h must declare the APB3 Slave 0 window size"
#endif
#if IO_APB_SLAVE_0_INPUT_SIZE < 0x60
#error "APB window is smaller than the accel_regs register map"
#endif
#define ACCEL_BASE ((uintptr_t)IO_APB_SLAVE_0_INPUT)
#define ACCEL_ID_EXPECTED      UINT32_C(0x4143434C)
#define ACCEL_VERSION_EXPECTED UINT32_C(0x00020000)
#define ACCEL_ID          0x00u
#define ACCEL_VERSION     0x04u
#define ACCEL_CONTROL     0x08u
#define ACCEL_STATUS      0x0Cu
#define ACCEL_RECT_X      0x10u
#define ACCEL_RECT_Y      0x14u
#define ACCEL_RECT_WIDTH  0x18u
#define ACCEL_RECT_HEIGHT 0x1Cu
#define ACCEL_RECT_COLOR  0x20u
#define ACCEL_ERROR_CODE  0x24u
#define ACCEL_SCRATCH     0x28u
#define ACCEL_FRONT_BASE  0x2Cu
#define ACCEL_BACK_BASE   0x30u
#define ACCEL_STRIDE      0x34u
#define ACCEL_WIDTH       0x38u
#define ACCEL_HEIGHT      0x3Cu
#define ACCEL_CAPABILITIES 0x40u
#define ACCEL_INIT_DATA_BEATS 0x44u
#define ACCEL_INIT_AW_BURSTS  0x48u
#define ACCEL_INIT_WLAST_BURSTS 0x4Cu
#define ACCEL_INIT_B_RESPONSES 0x50u
#define ACCEL_INIT_AW_BEATS   0x54u
#define ACCEL_WRITE_OWNER    0x58u
#define ACCEL_COMMAND_COUNT  0x5Cu
#define ACCEL_BUSY           (1u << 0)
#define ACCEL_DONE           (1u << 1)
#define ACCEL_ERROR          (1u << 2)
#define ACCEL_INIT_DONE      (1u << 3)
#define ACCEL_OWNER_ACCEL    (1u << 4)
#endif
