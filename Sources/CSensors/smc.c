#include "CSensors.h"
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <string.h>

// --- AppleSMC user client (same struct layout as smcFanControl / Stats / btop) ---
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } MPSMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } MPSMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } MPSMCKeyInfo;
typedef struct {
    uint32_t key;
    MPSMCVers vers;
    MPSMCPLimit pLimitData;
    MPSMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} MPSMCParam;

enum {
    kSMCHandleYPCEvent = 2,   // IOConnectCallStructMethod selector
    kSMCReadKey = 5,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo = 9,
};

#define FOURCC(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))

static io_connect_t gSMC = 0;

static int smc_call(MPSMCParam *in, MPSMCParam *out) {
    size_t size = sizeof(MPSMCParam);
    kern_return_t kr = IOConnectCallStructMethod(gSMC, kSMCHandleYPCEvent, in, sizeof(MPSMCParam), out, &size);
    return kr == KERN_SUCCESS && out->result == 0;
}

static int smc_key_info(uint32_t key, MPSMCKeyInfo *info) {
    MPSMCParam in = {0}, out = {0};
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    if (!smc_call(&in, &out)) return 0;
    *info = out.keyInfo;
    return 1;
}

static int smc_read(uint32_t key, uint32_t size, uint8_t bytes[32]) {
    MPSMCParam in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = kSMCReadKey;
    if (!smc_call(&in, &out)) return 0;
    memcpy(bytes, out.bytes, 32);
    return 1;
}

int mp_smc_open(void) {
    if (gSMC) return 1;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gSMC);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) { gSMC = 0; return 0; }
    return 1;
}

void mp_smc_close(void) {
    if (gSMC) { IOServiceClose(gSMC); gSMC = 0; }
}

int mp_smc_temperature_keys(uint32_t *keys, int max) {
    if (!gSMC || !keys || max <= 0) return 0;

    MPSMCKeyInfo info;
    uint8_t bytes[32];
    uint32_t countKey = FOURCC('#', 'K', 'E', 'Y');
    if (!smc_key_info(countKey, &info) || !smc_read(countKey, info.dataSize, bytes)) return 0;
    uint32_t total = (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | bytes[3];

    int found = 0;
    for (uint32_t i = 0; i < total && found < max; i++) {
        MPSMCParam in = {0}, out = {0};
        in.data8 = kSMCGetKeyFromIndex;
        in.data32 = i;
        if (!smc_call(&in, &out)) continue;
        if ((out.key >> 24) != 'T') continue;
        if (!smc_key_info(out.key, &info)) continue;
        if (info.dataType != FOURCC('f', 'l', 't', ' ') || info.dataSize != 4) continue;
        keys[found++] = out.key;
    }
    return found;
}

int mp_smc_read_floats(const uint32_t *keys, int count, float *out) {
    if (!gSMC || !keys || !out) return 0;
    int ok = 0;
    uint8_t bytes[32];
    for (int i = 0; i < count; i++) {
        if (smc_read(keys[i], 4, bytes)) {
            memcpy(&out[i], bytes, sizeof(float));   // 'flt ' is little-endian IEEE-754 on Apple Silicon
            ok++;
        } else {
            out[i] = NAN;
        }
    }
    return ok;
}
