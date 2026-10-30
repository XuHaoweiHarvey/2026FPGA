#ifndef GAME_FLASH_INTEGRATION_H
#define GAME_FLASH_INTEGRATION_H
#include "flash_store.h"
/* Diagnostic state survives in OCRAM for IDE inspection. No Flash boot. */
typedef struct {
    uint32_t jedec,error,asset_id,row,asset_crc,save_status,save_sequence,save_slot;
    uint32_t high_score,difficulty;
} game_flash_result_t;
extern volatile game_flash_result_t g_flash_result;
int game_flash_begin(void);
int game_flash_row(uint32_t index,uint32_t row,uint32_t pixels[640]);
uint32_t game_flash_expected_crc(uint32_t index);
int game_flash_update_score(uint32_t score);
#endif
