/*
 * mxswitch.c - switch a Logitech Easy-Switch device to another channel via
 *              HID++ 2.0 feature 0x1814 (ChangeHost). macOS, no dependencies.
 *
 * Build:
 *     clang -O2 -Wall -o mxswitch mxswitch.c \
 *         -framework IOKit -framework CoreFoundation -framework CoreGraphics
 *     codesign -s - mxswitch          # ad-hoc sign: keeps the TCC grant stable
 *
 * Usage:
 *     ./mxswitch --info
 *     ./mxswitch 2
 *     ./mxswitch --setup              # open Input Monitoring settings if needed
 *
 * Needs Input Monitoring (System Settings > Privacy & Security). Grant it to
 * this binary, and to whatever launches it (BetterTouchTool, Raycast, ...).
 */

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/hid/IOHIDManager.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#define LOGITECH_VID      0x046D
#define SW_ID             0x0A
#define ROOT_FEATURE      0x00
#define FEAT_CHANGE_HOST  0x1814

#define REPORT_SHORT 0x10
#define REPORT_LONG  0x11

static const uint8_t DEVICE_INDICES[] = { 0xFF, 0x01, 0x02, 0x03 };

/* ------------------------------------------------------------------ */

static int32_t prop_int(IOHIDDeviceRef dev, CFStringRef key) {
    CFTypeRef v = IOHIDDeviceGetProperty(dev, key);
    int32_t out = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, &out);
    return out;
}

static size_t frame_len(uint8_t report_id) {
    return report_id == REPORT_SHORT ? 7 : 20;
}

/* Filled in by the input report callback. */
static uint8_t  g_reply[64];
static CFIndex  g_reply_len;
static int      g_got_reply;

static void input_cb(void *ctx, IOReturn result, void *sender,
                     IOHIDReportType type, uint32_t report_id,
                     uint8_t *report, CFIndex len) {
    (void)ctx; (void)result; (void)sender; (void)type;

    if (len <= 0 || len > (CFIndex)sizeof(g_reply) - 1) goto done;

    /* IOKit is inconsistent about whether the report ID is included in the
     * buffer. HID++ always starts with 0x10 or 0x11, so normalise on that
     * rather than trusting either convention. */
    if (report_id != 0 && report[0] != (uint8_t)report_id) {
        g_reply[0] = (uint8_t)report_id;
        memcpy(g_reply + 1, report, (size_t)len);
        g_reply_len = len + 1;
    } else {
        memcpy(g_reply, report, (size_t)len);
        g_reply_len = len;
    }
    g_got_reply = 1;

done:
    CFRunLoopStop(CFRunLoopGetCurrent());
}

/*
 * Send one HID++ call. Returns 1 and fills *out on a matching reply, 0 on
 * timeout or error. Pass out == NULL for fire-and-forget (setCurrentHost never
 * answers - the link is already gone).
 */
static int hidpp_call(IOHIDDeviceRef dev, uint8_t report_id, uint8_t dev_idx,
                      uint8_t feature_idx, uint8_t function,
                      const uint8_t *params, size_t nparams,
                      uint8_t *out, double timeout_s) {
    uint8_t frame[20];
    size_t len = frame_len(report_id);

    memset(frame, 0, sizeof(frame));
    frame[0] = report_id;
    frame[1] = dev_idx;
    frame[2] = feature_idx;
    frame[3] = (uint8_t)((function << 4) | SW_ID);
    if (params && nparams) memcpy(frame + 4, params, nparams > 16 ? 16 : nparams);

    /* Report ID goes both in the buffer and as its own argument - this is what
     * hidapi does on macOS and what Logitech devices expect. */
    if (IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, report_id,
                             frame, len) != kIOReturnSuccess)
        return 0;

    if (!out) return 1;

    double remaining = timeout_s;
    while (remaining > 0) {
        g_got_reply = 0;
        g_reply_len = 0;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
        remaining -= 0.1;
        if (!g_got_reply || g_reply_len < 5) continue;
        if (g_reply[1] != dev_idx) continue;
        if (g_reply[2] == 0xFF || g_reply[2] == 0x8F) return 0;  /* error reply */
        if (g_reply[2] != feature_idx) continue;                 /* notification */
        if ((g_reply[3] & 0x0F) != SW_ID) continue;
        memcpy(out, g_reply, (size_t)g_reply_len);
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */

typedef struct {
    IOHIDManagerRef mgr;     /* kept alive while dev is open */
    IOHIDDeviceRef dev;
    uint8_t dev_idx, report_id, feature_idx;
    char name[128];
} target_t;

static void target_release(target_t *t) {
    if (t->dev) {
        IOHIDDeviceUnscheduleFromRunLoop(t->dev, CFRunLoopGetCurrent(),
                                         kCFRunLoopDefaultMode);
        IOHIDDeviceClose(t->dev, kIOHIDOptionsTypeNone);
        t->dev = NULL;
    }
    if (t->mgr) {
        CFRelease(t->mgr);
        t->mgr = NULL;
    }
}

/* Lower rank = try first. Mice before keyboards; vendor pages before others. */
static int name_has(const char *name, const char *needle) {
    return name && strcasestr(name, needle) != NULL;
}

static int device_rank(int32_t usage_page, int32_t usage, const char *name) {
    int mouse = (usage_page == 0x0001 && usage == 0x0002)
                || name_has(name, "master") || name_has(name, "anywhere")
                || name_has(name, "mouse") || name_has(name, "ergo");
    int kbd = (usage_page == 0x0001 && usage == 0x0006)
              || name_has(name, "keys") || name_has(name, "keyboard");
    int tier = (kbd && !mouse) ? 2 : (mouse ? 0 : 1);
    int non_vendor = usage_page >= 0xFF00 ? 0 : 1;
    return tier * 10 + non_vendor;
}

typedef struct {
    IOHIDDeviceRef dev;
    int32_t usage_page, usage, max_in;
    int rank;
    char name[128];
} cand_t;

static int cand_cmp(const void *a, const void *b) {
    return ((const cand_t *)a)->rank - ((const cand_t *)b)->rank;
}

static int find_device(target_t *t, int list_only) {
    memset(t, 0, sizeof(*t));

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                             kIOHIDOptionsTypeNone);
    if (!mgr) return 0;
    IOHIDManagerSetDeviceMatching(mgr, NULL);

    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    if (!set) { CFRelease(mgr); return 0; }

    CFIndex count = CFSetGetCount(set);
    IOHIDDeviceRef *devices = calloc((size_t)count, sizeof(IOHIDDeviceRef));
    CFSetGetValues(set, (const void **)devices);

    cand_t *cands = calloc((size_t)count, sizeof(cand_t));
    CFIndex ncand = 0;

    for (CFIndex i = 0; i < count; i++) {
        IOHIDDeviceRef d = devices[i];
        if (prop_int(d, CFSTR(kIOHIDVendorIDKey)) != LOGITECH_VID) continue;

        int32_t usage_page = prop_int(d, CFSTR(kIOHIDPrimaryUsagePageKey));
        int32_t usage      = prop_int(d, CFSTR(kIOHIDPrimaryUsageKey));
        int32_t max_in = prop_int(d, CFSTR(kIOHIDMaxInputReportSizeKey));
        if (max_in <= 0 || max_in > 64) max_in = 64;

        char name[128] = "(unnamed)";
        CFStringRef p = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductKey));
        if (p && CFGetTypeID(p) == CFStringGetTypeID())
            CFStringGetCString(p, name, sizeof(name), kCFStringEncodingUTF8);

        if (list_only) {
            printf("0x%04x:0x%04x  in=%d  %s\n", usage_page, usage, max_in, name);
            continue;
        }

        cands[ncand].dev = d;
        cands[ncand].usage_page = usage_page;
        cands[ncand].usage = usage;
        cands[ncand].max_in = max_in;
        cands[ncand].rank = device_rank(usage_page, usage, name);
        snprintf(cands[ncand].name, sizeof(cands[ncand].name), "%s", name);
        ncand++;
    }

    free(devices);
    CFRelease(set);

    if (list_only) {
        free(cands);
        CFRelease(mgr);
        return 0;
    }

    qsort(cands, (size_t)ncand, sizeof(cand_t), cand_cmp);

    const uint8_t probe[3] = { FEAT_CHANGE_HOST >> 8, FEAT_CHANGE_HOST & 0xFF, 0 };
    int found = 0;

    for (CFIndex i = 0; i < ncand && !found; i++) {
        IOHIDDeviceRef d = cands[i].dev;
        int32_t max_in = cands[i].max_in;

        if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess)
            continue;

        static uint8_t rxbuf[64];
        IOHIDDeviceRegisterInputReportCallback(d, rxbuf, max_in, input_cb, NULL);
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(),
                                       kCFRunLoopDefaultMode);

        uint8_t reply[64];
        const uint8_t rids[2] = { REPORT_LONG, REPORT_SHORT };
        for (size_t a = 0; a < sizeof(DEVICE_INDICES) && !found; a++) {
            for (size_t b = 0; b < 2 && !found; b++) {
                if (!hidpp_call(d, rids[b], DEVICE_INDICES[a], ROOT_FEATURE, 0,
                                probe, 3, reply, 0.25))
                    continue;
                if (reply[4] == 0) continue;     /* feature not supported */
                t->mgr = mgr;
                t->dev = d;
                t->dev_idx = DEVICE_INDICES[a];
                t->report_id = rids[b];
                t->feature_idx = reply[4];
                snprintf(t->name, sizeof(t->name), "%s", cands[i].name);
                found = 1;
            }
        }

        if (!found) {
            IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetCurrent(),
                                             kCFRunLoopDefaultMode);
            IOHIDDeviceClose(d, kIOHIDOptionsTypeNone);
        }
    }

    free(cands);
    if (!found) CFRelease(mgr);
    return found;
}

/* ------------------------------------------------------------------ */

#define TCC_SYSTEM_DB "/Library/Application Support/com.apple.TCC/TCC.db"
#define INPUT_MONITORING_SETTINGS \
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

/* Resolve this binary's real path for TCC client matching. */
static int own_executable_path(char *out, size_t out_sz) {
    char raw[PATH_MAX];
    char resolved[PATH_MAX];
    uint32_t size = sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0) return 0;
    const char *path = realpath(raw, resolved) ? resolved : raw;
    if (snprintf(out, out_sz, "%s", path) >= (int)out_sz) return 0;
    return 1;
}

/*
 * Is Input Monitoring already granted to *this* binary?
 * CGPreflightListenEventAccess() is not enough on its own: a Terminal that
 * already has the grant makes it return true for any child. Prefer the TCC
 * database row keyed by executable path; fall back to preflight only if the
 * DB is unreadable.
 *
 * Returns 1 = granted, 0 = not granted, -1 = unknown.
 */
static int input_monitoring_granted(void) {
    char exe[PATH_MAX];
    if (!own_executable_path(exe, sizeof(exe)))
        return CGPreflightListenEventAccess() ? 1 : 0;

    /* Escape single quotes for the sqlite query string. */
    char esc[PATH_MAX * 2];
    size_t j = 0;
    for (size_t i = 0; exe[i] && j + 2 < sizeof(esc); i++) {
        if (exe[i] == '\'') {
            esc[j++] = '\'';
            esc[j++] = '\'';
        } else {
            esc[j++] = exe[i];
        }
    }
    esc[j] = '\0';

    char cmd[PATH_MAX * 3];
    snprintf(cmd, sizeof(cmd),
             "/usr/bin/sqlite3 \"%s\" "
             "\"SELECT auth_value FROM access WHERE "
             "service='kTCCServiceListenEvent' AND client='%s' LIMIT 1;\" 2>/dev/null",
             TCC_SYSTEM_DB, esc);

    FILE *fp = popen(cmd, "r");
    if (!fp) return CGPreflightListenEventAccess() ? 1 : -1;

    char line[32] = "";
    if (!fgets(line, sizeof(line), fp)) {
        int status = pclose(fp);
        if (status != 0)
            return CGPreflightListenEventAccess() ? 1 : 0;
        /* No row for this path — not granted (or never prompted). */
        return 0;
    }
    int status = pclose(fp);
    if (status != 0) {
        /* DB unreadable (SIP / TCC protection). Fall back. */
        return CGPreflightListenEventAccess() ? 1 : 0;
    }

    /* auth_value 2 = allowed. 0 = denied. */
    int auth = atoi(line);
    return auth == 2 ? 1 : 0;
}

/* Open Input Monitoring settings unless this binary is already allowed. */
static int setup_input_monitoring(void) {
    int granted = input_monitoring_granted();
    if (granted == 1) {
        printf("Input Monitoring already granted for this binary.\n");
        return 0;
    }

    printf("Opening System Settings → Privacy & Security → Input Monitoring\n");
    printf("Enable mxswitch (use + to add it if it is not listed).\n");
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "/usr/bin/open '%s'", INPUT_MONITORING_SETTINGS);
    if (system(cmd) != 0) {
        fprintf(stderr, "Could not open System Settings. Enable Input Monitoring "
                        "manually under Privacy & Security.\n");
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s {1|2|3|--info|--list|--setup}\n", argv[0]);
        return 2;
    }

    if (strcmp(argv[1], "--setup") == 0)
        return setup_input_monitoring();

    if (strcmp(argv[1], "--list") == 0) {
        target_t t;
        find_device(&t, 1);
        return 0;
    }

    int want_info = strcmp(argv[1], "--info") == 0;
    int channel = 0;
    if (!want_info) {
        channel = atoi(argv[1]);
        if (channel < 1 || channel > 3) {
            fprintf(stderr, "channel must be 1, 2 or 3\n");
            return 2;
        }
    }

    target_t t;
    if (!find_device(&t, 0)) {
        fprintf(stderr, "No Logitech device supporting ChangeHost found.\n");
        fprintf(stderr, "Click the mouse to wake it, and check Input Monitoring.\n");
        return 1;
    }

    if (want_info) {
        uint8_t reply[64];
        printf("device     : %s\n", t.name);
        printf("transport  : %s  index=0x%02x  report=0x%02x\n",
               t.dev_idx == 0xFF ? "direct (BT/USB)" : "receiver",
               t.dev_idx, t.report_id);
        printf("ChangeHost : feature index 0x%02x\n", t.feature_idx);
        if (hidpp_call(t.dev, t.report_id, t.dev_idx, t.feature_idx, 0,
                       NULL, 0, reply, 0.4))
            printf("channels   : %d, currently on %d\n", reply[4], reply[5] + 1);
        target_release(&t);
        return 0;
    }

    printf("Switching to channel %d ...\n", channel);
    uint8_t host = (uint8_t)(channel - 1);
    hidpp_call(t.dev, t.report_id, t.dev_idx, t.feature_idx, 1, &host, 1, NULL, 0);
    target_release(&t);
    return 0;
}
