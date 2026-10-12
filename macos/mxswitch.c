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
 *     ./mxswitch --status
 *     ./mxswitch 2
 *     ./mxswitch --all 2
 *     ./mxswitch --toggle
 *     ./mxswitch --setup              # open Input Monitoring settings if needed
 *
 * Needs Input Monitoring (System Settings > Privacy & Security). Grant it to
 * this binary, and to whatever launches it (BetterTouchTool, Raycast, ...).
 *
 * Exit codes: 0 ok, 1 device not found, 2 bad usage, 3 partial --all failure.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/hid/IOHIDManager.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define LOGITECH_VID      0x046D
#define SW_ID             0x0A
#define ROOT_FEATURE      0x00
#define FEAT_CHANGE_HOST  0x1814
#define FEAT_DEVICE_FW    0x0003
#define FEAT_BATTERY_UNIFIED 0x1004
#define FEAT_BATTERY_LEVEL   0x1000

#define REPORT_SHORT 0x10
#define REPORT_LONG  0x11
#define MAX_DEVICES  8

static const uint8_t DEVICE_INDICES[] = { 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };

/* Reply classification, shared by the I/O loop and the tests. */
enum { REPLY_TOO_SHORT, REPLY_IGNORE, REPLY_ERROR, REPLY_MATCH };

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

/* Encode one HID++ request, zero-padded to the report length. Returns the
 * frame length, or 0 if the report id or parameter count is invalid. */
static size_t frame_build(uint8_t report_id, uint8_t dev_idx, uint8_t feature_idx,
                          uint8_t function, const uint8_t *params, size_t nparams,
                          uint8_t *out) {
    if (report_id != REPORT_SHORT && report_id != REPORT_LONG) return 0;
    size_t len = frame_len(report_id);
    if (nparams > len - 4) return 0;
    memset(out, 0, len);
    out[0] = report_id;
    out[1] = dev_idx;
    out[2] = feature_idx;
    out[3] = (uint8_t)((function << 4) | SW_ID);
    if (params && nparams) memcpy(out + 4, params, nparams);
    return len;
}

/* Match the reply-filtering rules in docs/protocol.md. */
static int classify_reply(const uint8_t *reply, size_t len,
                          uint8_t dev_idx, uint8_t feature_idx) {
    if (len < 5) return REPLY_TOO_SHORT;
    if (reply[1] != dev_idx) return REPLY_IGNORE;
    if (reply[2] == 0xFF || reply[2] == 0x8F) return REPLY_ERROR;
    if (reply[2] != feature_idx) return REPLY_IGNORE;
    if ((reply[3] & 0x0F) != SW_ID) return REPLY_IGNORE;
    return REPLY_MATCH;
}

/* Filled in by the input report callback. */
static uint8_t  g_reply[64];
static CFIndex  g_reply_len;
static int      g_got_reply;
static IOHIDDeviceRef g_reply_dev;

static void input_cb(void *ctx, IOReturn result, void *sender,
                     IOHIDReportType type, uint32_t report_id,
                     uint8_t *report, CFIndex len) {
    (void)ctx; (void)result; (void)type;

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
    /* Attribute the frame to its device: with several devices open (--all),
     * two identical models share device index, feature index and software id. */
    g_reply_dev = (IOHIDDeviceRef)sender;
    g_got_reply = 1;

done:
    CFRunLoopStop(CFRunLoopGetCurrent());
}

/*
 * Send one HID++ call. Returns 1 and fills *out (and *out_len, if given) on a
 * matching reply, 0 on timeout or error. Pass out == NULL for fire-and-forget
 * (setCurrentHost never answers - the link is already gone).
 */
static int hidpp_call(IOHIDDeviceRef dev, uint8_t report_id, uint8_t dev_idx,
                      uint8_t feature_idx, uint8_t function,
                      const uint8_t *params, size_t nparams,
                      uint8_t *out, size_t *out_len, double timeout_s) {
    uint8_t frame[20];
    size_t len = frame_build(report_id, dev_idx, feature_idx, function,
                             params, nparams, frame);
    if (!len) return 0;

    /* Report ID goes both in the buffer and as its own argument - this is what
     * hidapi does on macOS and what Logitech devices expect. */
    if (IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, report_id,
                             frame, len) != kIOReturnSuccess)
        return 0;

    if (!out) return 1;

    double deadline = CFAbsoluteTimeGetCurrent() + timeout_s;
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        g_got_reply = 0;
        g_reply_len = 0;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
        if (!g_got_reply || g_reply_len < 5) continue;
        if (g_reply_dev != dev) continue;   /* another open device spoke */
        int verdict = classify_reply(g_reply, (size_t)g_reply_len, dev_idx, feature_idx);
        if (verdict == REPLY_IGNORE || verdict == REPLY_TOO_SHORT) continue;
        if (verdict == REPLY_ERROR) return 0;
        memcpy(out, g_reply, (size_t)g_reply_len);
        if (out_len) *out_len = (size_t)g_reply_len;
        return 1;
    }
    return 0;
}

/* Resolve a feature ID to its runtime table index, or 0 if unsupported. */
static uint8_t resolve_feature(IOHIDDeviceRef dev, uint8_t report_id,
                               uint8_t dev_idx, uint16_t feature_id) {
    uint8_t probe[3] = { (uint8_t)(feature_id >> 8), (uint8_t)feature_id, 0 };
    uint8_t reply[64];
    if (!hidpp_call(dev, report_id, dev_idx, ROOT_FEATURE, 0, probe, 3,
                    reply, NULL, 0.3))
        return 0;
    return reply[4];
}

/* ------------------------------------------------------------------ */

typedef struct {
    uint8_t dev_idx, report_id, feature_idx;
    char name[128];
} device_info_t;

typedef struct {
    IOHIDManagerRef mgr;          /* kept alive while any dev is open */
    IOHIDDeviceRef devs[MAX_DEVICES];
    device_info_t info[MAX_DEVICES];
    int count;
} device_set_t;

static void devices_release(device_set_t *set) {
    for (int i = 0; i < set->count; i++) {
        IOHIDDeviceUnscheduleFromRunLoop(set->devs[i], CFRunLoopGetCurrent(),
                                         kCFRunLoopDefaultMode);
        IOHIDDeviceClose(set->devs[i], kIOHIDOptionsTypeNone);
    }
    set->count = 0;
    if (set->mgr) {
        CFRelease(set->mgr);
        set->mgr = NULL;
    }
}

/* Lower rank = try first. Mice before keyboards; vendor pages before others. */
static int name_has(const char *name, const char *needle) {
    return name && strcasestr(name, needle) != NULL;
}

/* No filter set, or the product name contains any of the substrings. */
static int name_matches(const char *name, const char *const *subs, int n) {
    if (!n) return 1;
    for (int i = 0; i < n; i++) {
        if (subs[i][0] && name_has(name, subs[i])) return 1;
    }
    return 0;
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

/*
 * Discover ChangeHost-capable devices. With want_all set, every unique device
 * (deduped by name + device index) is collected; otherwise the first ranked
 * one. When names are given, only devices whose product name contains one of
 * them are considered. Returns the number of devices in *set.
 */
static int find_devices(device_set_t *set, int want_all, int verbose,
                        const char *const *names, int name_count) {
    memset(set, 0, sizeof(*set));

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                             kIOHIDOptionsTypeNone);
    if (!mgr) return 0;
    IOHIDManagerSetDeviceMatching(mgr, NULL);

    CFSetRef cset = IOHIDManagerCopyDevices(mgr);
    if (!cset) { CFRelease(mgr); return 0; }

    CFIndex count = CFSetGetCount(cset);
    IOHIDDeviceRef *devices = calloc((size_t)count, sizeof(IOHIDDeviceRef));
    CFSetGetValues(cset, (const void **)devices);

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

        if (!name_matches(name, names, name_count)) continue;

        cands[ncand].dev = d;
        cands[ncand].usage_page = usage_page;
        cands[ncand].usage = usage;
        cands[ncand].max_in = max_in;
        cands[ncand].rank = device_rank(usage_page, usage, name);
        snprintf(cands[ncand].name, sizeof(cands[ncand].name), "%s", name);
        ncand++;
    }

    free(devices);
    CFRelease(cset);

    qsort(cands, (size_t)ncand, sizeof(cand_t), cand_cmp);

    for (CFIndex i = 0; i < ncand; i++) {
        if (!want_all && set->count > 0) break;
        IOHIDDeviceRef d = cands[i].dev;
        int32_t max_in = cands[i].max_in;

        if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess)
            continue;

        static uint8_t rxbuf[64];
        IOHIDDeviceRegisterInputReportCallback(d, rxbuf, max_in, input_cb, NULL);
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(),
                                       kCFRunLoopDefaultMode);

        const uint8_t probe[3] = { FEAT_CHANGE_HOST >> 8, FEAT_CHANGE_HOST & 0xFF, 0 };
        const uint8_t rids[2] = { REPORT_LONG, REPORT_SHORT };
        uint8_t reply[64];
        int matched = 0;
        uint8_t m_dev_idx = 0, m_report_id = 0, m_feature_idx = 0;

        for (size_t a = 0; a < sizeof(DEVICE_INDICES) && !matched; a++) {
            for (size_t b = 0; b < 2 && !matched; b++) {
                if (verbose)
                    fprintf(stderr, "probing %s index=0x%02x report=0x%02x\n",
                            cands[i].name, DEVICE_INDICES[a], rids[b]);
                if (!hidpp_call(d, rids[b], DEVICE_INDICES[a], ROOT_FEATURE, 0,
                                probe, 3, reply, NULL, 0.25))
                    continue;
                if (reply[4] == 0) continue;     /* feature not supported */
                matched = 1;
                m_dev_idx = DEVICE_INDICES[a];
                m_report_id = rids[b];
                m_feature_idx = reply[4];
            }
        }

        int duplicate = 0;
        for (int k = 0; k < set->count && matched; k++) {
            if (set->info[k].dev_idx == m_dev_idx &&
                strcasecmp(set->info[k].name, cands[i].name) == 0)
                duplicate = 1;
        }

        if (!matched || duplicate) {
            IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetCurrent(),
                                             kCFRunLoopDefaultMode);
            IOHIDDeviceClose(d, kIOHIDOptionsTypeNone);
            continue;
        }

        if (set->count >= MAX_DEVICES) {
            IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetCurrent(),
                                             kCFRunLoopDefaultMode);
            IOHIDDeviceClose(d, kIOHIDOptionsTypeNone);
            continue;
        }

        int n = set->count++;
        set->devs[n] = d;
        set->info[n].dev_idx = m_dev_idx;
        set->info[n].report_id = m_report_id;
        set->info[n].feature_idx = m_feature_idx;
        snprintf(set->info[n].name, sizeof(set->info[n].name), "%s", cands[i].name);
    }

    free(cands);
    if (set->count == 0) CFRelease(mgr);
    else set->mgr = mgr;
    return set->count;
}

static void list_devices(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                             kIOHIDOptionsTypeNone);
    if (!mgr) return;
    IOHIDManagerSetDeviceMatching(mgr, NULL);
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    if (!set) { CFRelease(mgr); return; }
    CFIndex count = CFSetGetCount(set);
    IOHIDDeviceRef *devices = calloc((size_t)count, sizeof(IOHIDDeviceRef));
    CFSetGetValues(set, (const void **)devices);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDDeviceRef d = devices[i];
        if (prop_int(d, CFSTR(kIOHIDVendorIDKey)) != LOGITECH_VID) continue;
        int32_t up = prop_int(d, CFSTR(kIOHIDPrimaryUsagePageKey));
        int32_t u  = prop_int(d, CFSTR(kIOHIDPrimaryUsageKey));
        int32_t mi = prop_int(d, CFSTR(kIOHIDMaxInputReportSizeKey));
        char name[128] = "(unnamed)";
        CFStringRef p = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductKey));
        if (p && CFGetTypeID(p) == CFStringGetTypeID())
            CFStringGetCString(p, name, sizeof(name), kCFStringEncodingUTF8);
        printf("0x%04x:0x%04x  in=%d  %s\n", up, u, mi, name);
    }
    free(devices);
    CFRelease(set);
    CFRelease(mgr);
}

/* ------------------------------------------------------------------ */
/* Config                                                              */

typedef struct {
    int channel_a, channel_b;     /* 0 means "not set / invalid" */
    char device[16];
    char name[256];               /* comma-separated --name substrings */
} config_t;

static const char *default_config_path(char *buf, size_t n) {
    const char *base = getenv("XDG_CONFIG_HOME");
    const char *home = getenv("HOME");
    if (base && *base) snprintf(buf, n, "%s/mxswitch/config", base);
    else if (home && *home) snprintf(buf, n, "%s/.config/mxswitch/config", home);
    else return NULL;
    return buf;
}

/* Strict base-10 integer: the whole value must be numeric, else 0. */
static int config_int(const char *s) {
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end == s) return 0;
    while (*end && isspace((unsigned char)*end)) end++;
    if (*end) return 0;
    if (v < INT_MIN || v > INT_MAX) return 0;
    return (int)v;
}

static void config_load(config_t *cfg, const char *path) {
    cfg->channel_a = 1;
    cfg->channel_b = 2;
    snprintf(cfg->device, sizeof(cfg->device), "primary");
    cfg->name[0] = '\0';
    char def[PATH_MAX];
    if (!path) path = default_config_path(def, sizeof(def));
    if (!path) return;
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *hash = strchr(line, '#');
        if (hash) *hash = '\0';
        char *s = line;
        while (*s && isspace((unsigned char)*s)) s++;
        char *end = s + strlen(s);
        while (end > s && isspace((unsigned char)end[-1])) *--end = '\0';
        if (!*s) continue;

        /* Split on the first '=' and trim both sides, so "key = value" and
         * "key=value" both parse. */
        char *eq = strchr(s, '=');
        if (!eq) continue;
        *eq = '\0';
        char *kend = s + strlen(s);
        while (kend > s && isspace((unsigned char)kend[-1])) *--kend = '\0';
        char *value = eq + 1;
        while (*value && isspace((unsigned char)*value)) value++;

        if (strcmp(s, "channel_a") == 0) {
            cfg->channel_a = config_int(value);   /* 0 if junk; validated below */
        } else if (strcmp(s, "channel_b") == 0) {
            cfg->channel_b = config_int(value);
        } else if (strcmp(s, "device") == 0) {
            snprintf(cfg->device, sizeof(cfg->device), "%s", value);
        } else if (strcmp(s, "name") == 0) {
            snprintf(cfg->name, sizeof(cfg->name), "%s", value);
        }
    }
    fclose(f);
}

/* Returns the first problem, or NULL if the config is usable for --toggle. */
static const char *config_problem(const config_t *cfg) {
    if (cfg->channel_a < 1 || cfg->channel_a > 3 ||
        cfg->channel_b < 1 || cfg->channel_b > 3)
        return "channel_a and channel_b must be 1, 2 or 3";
    if (cfg->channel_a == cfg->channel_b)
        return "channel_a and channel_b must differ";
    if (strcmp(cfg->device, "primary") != 0 && strcmp(cfg->device, "all") != 0)
        return "device must be primary or all";
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Output                                                              */

static void json_string(const char *s) {
    putchar('"');
    for (; s && *s; s++) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
        case '"':  fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\b': fputs("\\b", stdout); break;
        case '\f': fputs("\\f", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (c < 0x20) printf("\\u%04x", c);
            else putchar(c);
        }
    }
    putchar('"');
}

typedef struct {
    int hosts, channel;           /* channel 1-based; 0 if unknown */
    int has_battery, battery, charging;
    char firmware[32];
} status_t;

static void gather_status(IOHIDDeviceRef dev, const device_info_t *di,
                          int want_status, status_t *st) {
    memset(st, 0, sizeof(*st));
    memset(st->firmware, 0, sizeof(st->firmware));
    uint8_t reply[64];
    size_t rlen = 0;
    if (hidpp_call(dev, di->report_id, di->dev_idx, di->feature_idx, 0,
                   NULL, 0, reply, &rlen, 0.4) && rlen >= 6) {
        st->hosts = reply[4];
        st->channel = reply[5] + 1;
    }
    if (!want_status) return;

    const uint16_t bids[2] = { FEAT_BATTERY_UNIFIED, FEAT_BATTERY_LEVEL };
    for (int i = 0; i < 2 && !st->has_battery; i++) {
        uint8_t idx = resolve_feature(dev, di->report_id, di->dev_idx, bids[i]);
        if (!idx) continue;
        if (!hidpp_call(dev, di->report_id, di->dev_idx, idx, 0,
                        NULL, 0, reply, &rlen, 0.3) || rlen < 6)
            continue;
        st->has_battery = 1;
        st->battery = reply[4];
        st->charging = reply[5] & 0x01;
    }

    uint8_t fw_idx = resolve_feature(dev, di->report_id, di->dev_idx, FEAT_DEVICE_FW);
    if (fw_idx &&
        hidpp_call(dev, di->report_id, di->dev_idx, fw_idx, 0, NULL, 0,
                   reply, &rlen, 0.3) &&
        rlen >= 8 && reply[4] > 0 && (reply[6] || reply[7]))
        snprintf(st->firmware, sizeof(st->firmware), "%d.%d", reply[6], reply[7]);
}

static void print_human(const device_info_t *di, const status_t *st) {
    printf("device     : %s\n", di->name);
    printf("transport  : %s  index=0x%02x  report=0x%02x\n",
           di->dev_idx == 0xFF ? "direct (BT/USB)" : "receiver",
           di->dev_idx, di->report_id);
    printf("ChangeHost : feature index 0x%02x\n", di->feature_idx);
    if (st->hosts)
        printf("channels   : %d, currently on %d\n", st->hosts, st->channel);
    if (st->has_battery)
        printf("battery    : %d%% (%s)\n", st->battery,
               st->charging ? "charging" : "discharging");
    if (st->firmware[0]) printf("firmware   : %s\n", st->firmware);
}

static void print_json(const device_info_t *di, const status_t *st, int last) {
    printf("{");
    printf("\"product\":"); json_string(di->name);
    printf(",\"transport\":\"%s\"", di->dev_idx == 0xFF ? "direct (BT/USB)" : "receiver");
    printf(",\"device_index\":%d", di->dev_idx);
    printf(",\"report_id\":%d", di->report_id);
    printf(",\"feature_index\":%d", di->feature_idx);
    if (st->hosts) printf(",\"hosts\":%d,\"channel\":%d", st->hosts, st->channel);
    if (st->has_battery)
        printf(",\"battery_percent\":%d,\"charging\":%s",
               st->battery, st->charging ? "true" : "false");
    if (st->firmware[0]) { printf(",\"firmware\":"); json_string(st->firmware); }
    printf("}%s", last ? "" : ",");
}

/* ------------------------------------------------------------------ */
/* Input Monitoring setup (macOS onboarding)                           */

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
 * Run `/usr/bin/sqlite3 <db> <query>` without a shell, so a path embedded in
 * the query can never be reinterpreted as shell input. Reads at most out_sz-1
 * bytes of stdout. Returns the bytes read, or -1 if the process could not run
 * or exited non-zero (e.g. the DB is TCC-protected).
 */
static int spawn_sqlite(const char *db, const char *query,
                        char *out, size_t out_sz) {
    int pfd[2];
    if (pipe(pfd) != 0) return -1;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);
    posix_spawn_file_actions_addclose(&fa, pfd[1]);

    char *argv[] = { (char *)"/usr/bin/sqlite3", (char *)db,
                     (char *)query, NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, "/usr/bin/sqlite3", &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pfd[1]);
    if (rc != 0) {
        close(pfd[0]);
        return -1;
    }

    size_t total = 0;
    for (;;) {
        ssize_t n = read(pfd[0], out + total, out_sz - 1 - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (n == 0) break;
        total += (size_t)n;
        if (total >= out_sz - 1) break;
    }
    out[total] = '\0';
    close(pfd[0]);

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return -1;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return -1;
    return (int)total;
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

    /* Double single quotes for the SQL string literal. */
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

    char query[PATH_MAX * 2 + 128];
    snprintf(query, sizeof(query),
             "SELECT auth_value FROM access WHERE "
             "service='kTCCServiceListenEvent' AND client='%s' LIMIT 1;", esc);

    char line[32];
    int n = spawn_sqlite(TCC_SYSTEM_DB, query, line, sizeof(line));
    if (n < 0)
        /* DB unreadable (SIP / TCC protection). Fall back. */
        return CGPreflightListenEventAccess() ? 1 : 0;
    if (n == 0)
        /* No row for this path — not granted (or never prompted). */
        return 0;
    /* auth_value 2 = allowed. 0 = denied. */
    return atoi(line) == 2 ? 1 : 0;
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

#define MAX_NAME_FILTERS 16

typedef struct {
    const char *mode;             /* info status list toggle setup, or NULL */
    int mode_count;               /* how many mode flags were given */
    int channel;                  /* 0 = unset */
    int all, dry, json, verbose;
    const char *config_path;
    const char *names[MAX_NAME_FILTERS];  /* --name substrings, OR'd */
    int name_count;
} opts_t;

static void usage(const char *prog) {
    fprintf(stderr,
            "usage: %s {1|2|3|--info|--status|--toggle|--list|--setup} "
            "[--all] [--name SUBSTR] [--dry-run] [--json] [--verbose] "
            "[--config PATH]\n", prog);
}

#ifndef MXSWITCH_TEST

int main(int argc, char **argv) {
    opts_t o = { 0 };
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "1") || !strcmp(a, "2") || !strcmp(a, "3")) o.channel = atoi(a);
        else if (!strcmp(a, "--info")) { o.mode = "info"; o.mode_count++; }
        else if (!strcmp(a, "--status")) { o.mode = "status"; o.mode_count++; }
        else if (!strcmp(a, "--toggle")) { o.mode = "toggle"; o.mode_count++; }
        else if (!strcmp(a, "--list")) { o.mode = "list"; o.mode_count++; }
        else if (!strcmp(a, "--setup")) { o.mode = "setup"; o.mode_count++; }
        else if (!strcmp(a, "--all")) o.all = 1;
        else if (!strcmp(a, "--dry-run")) o.dry = 1;
        else if (!strcmp(a, "--json")) o.json = 1;
        else if (!strcmp(a, "--verbose")) o.verbose = 1;
        else if (!strcmp(a, "--config") && i + 1 < argc) o.config_path = argv[++i];
        else if (!strcmp(a, "--name") && i + 1 < argc) {
            if (o.name_count < MAX_NAME_FILTERS) o.names[o.name_count++] = argv[++i];
            else i++;
        }
        else { usage(argv[0]); return 2; }
    }

    if (o.mode_count > 1) {
        fprintf(stderr, "--info, --status, --toggle, --list and --setup are "
                        "mutually exclusive\n");
        return 2;
    }

    if (o.mode && !strcmp(o.mode, "setup"))
        return setup_input_monitoring();
    if (o.mode && !strcmp(o.mode, "list")) { list_devices(); return 0; }

    config_t cfg;
    config_load(&cfg, o.config_path);
    if (o.all || strcmp(cfg.device, "all") == 0) o.all = 1;

    if (o.mode && !strcmp(o.mode, "toggle")) {
        const char *problem = config_problem(&cfg);
        if (problem) {
            fprintf(stderr, "Cannot toggle: %s\n", problem);
            return 2;
        }
    } else if (!o.mode && o.channel == 0) {
        usage(argv[0]);
        return 2;
    }

    if (o.verbose) {
        char def[PATH_MAX];
        const char *path = o.config_path ? o.config_path
                                          : default_config_path(def, sizeof(def));
        fprintf(stderr, "config     : %s\n", path ? path : "(none)");
    }

    /* Union of --name filters and the config `name` list, comma-separated. */
    const char *names[MAX_NAME_FILTERS];
    int name_count = 0;
    for (int i = 0; i < o.name_count && name_count < MAX_NAME_FILTERS; i++)
        names[name_count++] = o.names[i];
    if (cfg.name[0]) {
        char *save = NULL;
        for (char *tok = strtok_r(cfg.name, ",", &save);
             tok && name_count < MAX_NAME_FILTERS;
             tok = strtok_r(NULL, ",", &save)) {
            while (*tok == ' ' || *tok == '\t') tok++;
            char *e = tok + strlen(tok);
            while (e > tok && (e[-1] == ' ' || e[-1] == '\t')) *--e = '\0';
            if (*tok) names[name_count++] = tok;
        }
    }

    device_set_t set;
    int found = find_devices(&set, o.all, o.verbose, names, name_count);
    if (!found) {
        fprintf(stderr, "No Logitech device supporting ChangeHost found.\n");
        fprintf(stderr, "Click the mouse to wake it, and check Input Monitoring.\n");
        return 1;
    }

    int want_info = o.mode && (!strcmp(o.mode, "info") || !strcmp(o.mode, "status"));
    int want_status = o.mode && !strcmp(o.mode, "status");

    if (want_info) {
        if (o.json) putchar('[');
        for (int i = 0; i < set.count; i++) {
            status_t st;
            gather_status(set.devs[i], &set.info[i], want_status, &st);
            if (o.json) print_json(&set.info[i], &st, i == set.count - 1);
            else {
                if (i) putchar('\n');
                print_human(&set.info[i], &st);
            }
        }
        if (o.json) puts("]");
        devices_release(&set);
        return 0;
    }

    int channel = o.channel;
    if (o.mode && !strcmp(o.mode, "toggle")) {
        uint8_t reply[64];
        if (!hidpp_call(set.devs[0], set.info[0].report_id, set.info[0].dev_idx,
                        set.info[0].feature_idx, 0, NULL, 0, reply, NULL, 0.4)) {
            fprintf(stderr, "Could not read the current channel.\n");
            devices_release(&set);
            return 1;
        }
        int current = reply[5] + 1;
        if (current == cfg.channel_a) channel = cfg.channel_b;
        else if (current == cfg.channel_b) channel = cfg.channel_a;
        else {
            fprintf(stderr, "Current channel %d is not in the configured pair "
                            "%d,%d. Refusing to guess.\n",
                    current, cfg.channel_a, cfg.channel_b);
            devices_release(&set);
            return 1;
        }
    }

    if (channel < 1 || channel > 3) {
        fprintf(stderr, "channel must be 1, 2 or 3\n");
        devices_release(&set);
        return 2;
    }

    uint8_t host = (uint8_t)(channel - 1);
    int failures = 0;

    if (o.dry) {
        for (int i = 0; i < set.count; i++) {
            uint8_t frame[20];
            size_t len = frame_build(set.info[i].report_id, set.info[i].dev_idx,
                                     set.info[i].feature_idx, 1, &host, 1, frame);
            printf("%s: switch to channel %d -> ", set.info[i].name, channel);
            for (size_t b = 0; b < len; b++) printf("%02x", frame[b]);
            putchar('\n');
        }
        devices_release(&set);
        return 0;
    }

    printf("Switching to channel %d ...\n", channel);
    for (int i = 0; i < set.count; i++) {
        int sent = hidpp_call(set.devs[i], set.info[i].report_id,
                              set.info[i].dev_idx, set.info[i].feature_idx,
                              1, &host, 1, NULL, NULL, 0);
        if (sent) printf("  %s: command sent\n", set.info[i].name);
        else { fprintf(stderr, "  %s: failed\n", set.info[i].name); failures++; }
    }

    devices_release(&set);
    if (!failures) return 0;
    if (failures == found) return 1;
    fprintf(stderr, "%d of %d devices failed.\n", failures, found);
    return 3;
}

#endif /* MXSWITCH_TEST */
