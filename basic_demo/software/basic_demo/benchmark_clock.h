#ifndef BENCHMARK_CLOCK_H
#define BENCHMARK_CLOCK_H
#include <stdint.h>
#include "soc.h"

#if !defined(SYSTEM_CLINT_HZ) || SYSTEM_CLINT_HZ == 0
#error "Benchmark requires the formal BSP CLINT frequency"
#endif
#if !defined(SYSTEM_CLINT_CTRL_SIZE) || SYSTEM_CLINT_CTRL_SIZE < 0xC000
#error "Benchmark requires the formal CLINT time register window"
#endif

/* RV32: retry a high/low/high read if the low word rolled over. The caller
 * supplies ordered MMIO reads; using CLINT avoids assumptions about mcycle
 * enable/debug behavior. This is elapsed time, not CPU utilization. */
static inline uint64_t benchmark_clock_read(uint32_t (*read32)(uintptr_t)) {
    const uintptr_t low=(uintptr_t)SYSTEM_CLINT_CTRL+UINT32_C(0xBFF8);
    uint32_t hi,lo;
    do {
        hi=read32(low+4u);
        lo=read32(low);
    } while(hi!=read32(low+4u));
    return ((uint64_t)hi<<32)|lo;
}
#endif
