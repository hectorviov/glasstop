#include "CSensors.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <string.h>

// --- Private IOKit HID API (used by Stats, btop, iStat, etc.) -------------
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define IOHIDEventFieldBase(type) ((type) << 16)
#define kHIDPage_AppleVendor 0xff00
#define kHIDUsage_AppleVendor_TemperatureSensor 0x0005
#define MP_MAX_SERVICES 256

static IOHIDEventSystemClientRef gClient = NULL;
static CFArrayRef gServices = NULL;
// Services worth reading, with their names cached (each read costs ~0.75 ms on M5 Pro).
static IOHIDServiceClientRef gUseful[MP_MAX_SERVICES];
static char gNames[MP_MAX_SERVICES][64];
static int gUsefulCount = 0;

static void mp_init(void) {
    if (gClient && gServices) return;
    if (!gClient) gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gClient) return;

    int page = kHIDPage_AppleVendor, usage = kHIDUsage_AppleVendor_TemperatureSensor;
    CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { pageNum, usageNum };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(gClient, match);
    CFRelease(match);
    CFRelease(pageNum);
    CFRelease(usageNum);

    gServices = IOHIDEventSystemClientCopyServices(gClient);
    gUsefulCount = 0;
    if (!gServices) return;

    CFIndex count = CFArrayGetCount(gServices);
    for (CFIndex i = 0; i < count && gUsefulCount < MP_MAX_SERVICES; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices, i);
        if (!svc) continue;
        char *name = gNames[gUsefulCount];
        name[0] = 0;
        CFTypeRef product = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (product) {
            if (CFGetTypeID(product) == CFStringGetTypeID()) {
                CFStringGetCString((CFStringRef)product, name, 64, kCFStringEncodingUTF8);
            }
            CFRelease(product);
        }
        // "tdev" sensors read ~-9200 °C and "tcal" is a calibration value: skip both.
        if (strstr(name, "tdev") || strstr(name, "tcal")) continue;
        gUseful[gUsefulCount++] = svc;   // owned by gServices
    }
}

void mp_temperature_reset(void) {
    gUsefulCount = 0;
    if (gServices) { CFRelease(gServices); gServices = NULL; }
    if (gClient) { CFRelease(gClient); gClient = NULL; }
}

int mp_read_temperatures(MPSensorReading *out, int max) {
    mp_init();
    if (!gServices || !out || max <= 0) return 0;

    int written = 0;
    for (int i = 0; i < gUsefulCount && written < max; i++) {
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(gUseful[i], kIOHIDEventTypeTemperature, 0, 0);
        if (!ev) continue;
        double value = IOHIDEventGetFloatValue(ev, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
        CFRelease(ev);

        MPSensorReading *r = &out[written++];
        memcpy(r->name, gNames[i], sizeof(r->name));
        r->celsius = value;
    }
    return written;
}
