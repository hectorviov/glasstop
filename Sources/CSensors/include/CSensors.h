#ifndef CSENSORS_H
#define CSENSORS_H

#include <stdint.h>

typedef struct {
    char name[64];
    double celsius;
} MPSensorReading;

// --- HID (fallback) ---------------------------------------------------------
// ~0.75 ms per sensor on M5 Pro, so it is only used when the SMC path finds nothing.

/// Reads the HID temperature sensors (Apple Silicon), skipping the bogus
/// "tdev"/"tcal" services. Returns the number of entries written to `out`
/// (<= max). Not thread-safe: call from one queue only.
int mp_read_temperatures(MPSensorReading *out, int max);

/// Drops the cached HID client/services so the next read re-discovers sensors
/// (call periodically and after wake from sleep).
void mp_temperature_reset(void);

// --- SMC (primary) ----------------------------------------------------------
// ~0.15 ms per key. Not thread-safe: call from one queue only.

/// Opens the AppleSMC user client. Returns 1 on success.
int mp_smc_open(void);
void mp_smc_close(void);

/// Enumerates every 4-byte float key starting with 'T' (temperatures).
/// Returns the number of keys written to `keys` (<= max). Slow (~0.5 s): call once.
int mp_smc_temperature_keys(uint32_t *keys, int max);

/// Reads `count` float keys into `out` (NaN for keys that fail). Returns the
/// number read successfully.
int mp_smc_read_floats(const uint32_t *keys, int count, float *out);

#endif
