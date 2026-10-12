/* Test-only IOKit boundary: the real discovery and request code still runs. */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    CFMutableDictionaryRef properties;
    const char *names[7];
    uint32_t units[7];
    int close_count;
    IOHIDReportCallback callback;
    uint8_t pending[20];
    CFIndex pending_len;
} fake_hid_t;

static CFMutableSetRef fake_devices;
static fake_hid_t *fake_pending;

static IOHIDManagerRef fake_manager_create(CFAllocatorRef allocator, IOOptionBits options) {
    (void)allocator; (void)options;
    return (IOHIDManagerRef)CFRetain(fake_devices);
}
static void fake_matching(IOHIDManagerRef manager, CFDictionaryRef matching) { (void)manager; (void)matching; }
static CFSetRef fake_copy_devices(IOHIDManagerRef manager) { return CFRetain(manager); }
static CFTypeRef fake_property(IOHIDDeviceRef dev, CFStringRef key) {
    return CFDictionaryGetValue(((fake_hid_t *)dev)->properties, key);
}
static IOReturn fake_open(IOHIDDeviceRef dev, IOOptionBits options) { (void)dev; (void)options; return kIOReturnSuccess; }
static IOReturn fake_close(IOHIDDeviceRef dev, IOOptionBits options) {
    (void)options; ((fake_hid_t *)dev)->close_count++; return kIOReturnSuccess;
}
static void fake_callback(IOHIDDeviceRef dev, uint8_t *buffer, CFIndex length, IOHIDReportCallback cb, void *ctx) {
    (void)buffer; (void)length; (void)ctx; ((fake_hid_t *)dev)->callback = cb;
}
static void fake_schedule(IOHIDDeviceRef dev, CFRunLoopRef loop, CFStringRef mode) { (void)dev; (void)loop; (void)mode; }
static io_service_t fake_service(IOHIDDeviceRef dev) { (void)dev; return 0; }

static IOReturn fake_set_report(IOHIDDeviceRef dev, IOHIDReportType type, CFIndex report_id,
                                const uint8_t *frame, CFIndex length) {
    (void)type; (void)report_id; (void)length;
    fake_hid_t *d = (fake_hid_t *)dev;
    unsigned slot = frame[1] == 255 ? 0 : frame[1];
    if (slot > 6 || !d->names[slot]) return kIOReturnUnsupported;
    unsigned feature = frame[2], function = frame[3] >> 4;
    memset(d->pending, 0, sizeof(d->pending));
    d->pending[0] = 17; d->pending[1] = frame[1];
    d->pending[2] = frame[2]; d->pending[3] = frame[3];
    if (!feature) {
        unsigned fid = ((unsigned)frame[4] << 8) | frame[5];
        d->pending[4] = fid == 0x1814 ? 10 : fid == 5 ? 5 : fid == 3 ? 3 : fid == 0x1004 ? 6 : 0;
    } else if (feature == 5) {
        if (!function) d->pending[4] = (uint8_t)strlen(d->names[slot]);
        else {
            size_t remaining = strlen(d->names[slot]) - frame[4];
            memcpy(d->pending + 4, d->names[slot] + frame[4], remaining > 16 ? 16 : remaining);
        }
    } else if (feature == 3) {
        if (!function) {
            d->pending[4] = 2;
            for (int i = 0; i < 4; i++) d->pending[5+i] = (uint8_t)(d->units[slot] >> (24-8*i));
        } else {
            d->pending[4] = frame[4] == 0 ? 1 : 0;
            memcpy(d->pending + 5, "RMP", 3);
            d->pending[8] = 0x12; d->pending[9] = 0x34;
            d->pending[10] = 0xab; d->pending[11] = 0xcd;
        }
    } else if (feature == 6) {
        d->pending[4] = function ? 88 : 2;
        d->pending[5] = 80; d->pending[6] = 1;
    } else if (feature == 10) {
        d->pending[4] = 3; d->pending[5] = 0;
    }
    d->pending_len = 20;
    fake_pending = d;
    return kIOReturnSuccess;
}
static SInt32 fake_run_loop(CFStringRef mode, CFTimeInterval timeout, Boolean once) {
    (void)mode; (void)timeout; (void)once;
    if (fake_pending) {
        fake_hid_t *d = fake_pending; fake_pending = NULL;
        d->callback(NULL, kIOReturnSuccess, d, kIOHIDReportTypeInput, 17, d->pending, d->pending_len);
    }
    return kCFRunLoopRunHandledSource;
}
static void fake_stop(CFRunLoopRef loop) { (void)loop; }

#define IOHIDManagerCreate fake_manager_create
#define IOHIDManagerSetDeviceMatching fake_matching
#define IOHIDManagerCopyDevices fake_copy_devices
#define IOHIDDeviceGetProperty fake_property
#define IOHIDDeviceOpen fake_open
#define IOHIDDeviceClose fake_close
#define IOHIDDeviceRegisterInputReportCallback fake_callback
#define IOHIDDeviceScheduleWithRunLoop fake_schedule
#define IOHIDDeviceUnscheduleFromRunLoop fake_schedule
#define IOHIDDeviceGetService fake_service
#define IOHIDDeviceSetReport fake_set_report
#define CFRunLoopRunInMode fake_run_loop
#define CFRunLoopStop fake_stop
