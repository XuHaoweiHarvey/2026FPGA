#ifndef GAME_STRESS_TUNING_H
#define GAME_STRESS_TUNING_H
#include <stdint.h>
#define GAME_STRESS_MAGIC UINT32_C(0x47535431)
/* Optional extension; original 32-byte command mailbox/status ABI is unchanged. */
typedef struct {
    uint32_t magic, version, enemy_capacity, enemy_bullet_capacity;
} game_stress_limits_t;
typedef struct {
    uint32_t enemies, enemy_bullets;
} game_stress_request_t;
typedef struct {
    uint32_t magic, version, enemies, enemy_bullets;
    uint32_t rendered_enemies, rendered_enemy_bullets;
    uint32_t measurement_min_enemies, measurement_max_enemies;
    uint32_t measurement_min_enemy_bullets, measurement_max_enemy_bullets;
    uint32_t measurement_enemies, measurement_enemy_bullets;
} game_stress_status_t;
#endif
