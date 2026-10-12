/*
 * Hardware-free tests for macos/mxswitch.c.
 *
 * The implementation is compiled into this translation unit with MXSWITCH_TEST
 * set, so main() there is skipped and the static frame helpers are reachable.
 *
 * Run with ./tests/run.sh, which generates the shared fixture header.
 */

#ifndef MXSWITCH_TEST
#define MXSWITCH_TEST
#endif

#include "fake_iokit.h"
#include "../macos/mxswitch.c"

static int fails;

static void hex_of(const uint8_t *b, size_t n, char *out) {
    for (size_t i = 0; i < n; i++) snprintf(out + i * 2, 3, "%02x", b[i]);
    out[n * 2] = '\0';
}

static void check_frame(const char *name, uint8_t report_id, uint8_t dev_idx,
                        uint8_t feature_idx, uint8_t function,
                        const uint8_t *params, size_t nparams,
                        const char *expected) {
    uint8_t frame[20];
    char hex[64];
    size_t len = frame_build(report_id, dev_idx, feature_idx, function,
                             params, nparams, frame);
    if (!len) { printf("FAIL: %s (frame_build returned 0)\n", name); fails++; return; }
    hex_of(frame, len, hex);
    if (strcmp(hex, expected) != 0) {
        printf("FAIL: %s\n  expected: %s\n  actual:   %s\n", name, expected, hex);
        fails++;
    }
}

static void check_reply(const char *name, const char *hex,
                        uint8_t dev_idx, uint8_t feature_idx, uint8_t function, int expected) {
    uint8_t reply[64];
    size_t n = strlen(hex) / 2;
    for (size_t i = 0; i < n; i++) {
        unsigned v;
        sscanf(hex + i * 2, "%2x", &v);
        reply[i] = (uint8_t)v;
    }
    int got = classify_reply(reply, n, dev_idx, feature_idx, function, SW_ID);
    if (got != expected) {
        printf("FAIL: %s (got %d, expected %d)\n", name, got, expected);
        fails++;
    }
}

static void check_config(void) {
    char path[] = "/tmp/mxswitch-test-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) { printf("FAIL: mkstemp\n"); fails++; return; }
    const char *text = "# comment\nchannel_a = 3\nchannel_b=1\ndevice = all\n"
                       "name = MX Keys, MX Master\n";
    if (write(fd, text, strlen(text)) != (ssize_t)strlen(text)) {
        printf("FAIL: config write\n"); fails++;
    }
    close(fd);
    config_t c;
    config_load(&c, path);
    unlink(path);
    /* Spaces around '=' must parse, matching the other implementations. */
    if (c.channel_a != 3 || c.channel_b != 1 || strcmp(c.device, "all") != 0) {
        printf("FAIL: config spaces parse (a=%d b=%d dev=%s)\n",
               c.channel_a, c.channel_b, c.device);
        fails++;
    }
    /* The name list keeps its internal spaces. */
    if (strcmp(c.name, "MX Keys, MX Master") != 0) {
        printf("FAIL: config name parse (name='%s')\n", c.name);
        fails++;
    }
    /* A missing file keeps the defaults. */
    config_load(&c, "/nonexistent/mxswitch/config");
    if (c.channel_a != 1 || c.channel_b != 2 ||
        strcmp(c.device, "primary") != 0 || c.name[0] != '\0') {
        printf("FAIL: config defaults\n");
        fails++;
    }
}

static void check_name(void) {
    const char *only_keys[] = { "keys" };
    const char *master[] = { "master" };
    const char *either[] = { "nope", "master" };
    const char *blank[] = { "" };
    struct { const char *name; const char *const *subs; int n; int want; } cases[] = {
        { "MX Master 3S", NULL, 0, 1 },          /* no filter matches all */
        { NULL, only_keys, 1, 0 },
        { "MX Keys S", only_keys, 1, 1 },        /* case-insensitive */
        { "MX Keys S", master, 1, 0 },
        { "MX Master 3S", either, 2, 1 },        /* any filter matches */
        { "MX Keys S", blank, 1, 0 },            /* empty filter ignored */
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        if (name_matches(cases[i].name, cases[i].subs, cases[i].n) != cases[i].want) {
            printf("FAIL: name_matches(%s, n=%d)\n",
                   cases[i].name ? cases[i].name : "(null)", cases[i].n);
            fails++;
        }
    }
}

static void fake_init(fake_hid_t *d, const char *product) {
    memset(d, 0, sizeof(*d));
    d->properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const char *keys[] = { kIOHIDVendorIDKey, kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey, kIOHIDMaxInputReportSizeKey };
    int values[] = { 0x046d, 0xff00, 1, 20 };
    for (int i = 0; i < 4; i++) {
        CFStringRef key = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
        CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &values[i]);
        CFDictionarySetValue(d->properties, key, value); CFRelease(key); CFRelease(value);
    }
    CFStringRef name = CFStringCreateWithCString(NULL, product, kCFStringEncodingUTF8);
    CFDictionarySetValue(d->properties, CFSTR(kIOHIDProductKey), name); CFRelease(name);
    CFSetAddValue(fake_devices, d);
}

static void check_discovery(void) {
    fake_hid_t receiver, collection, mouse;
    fake_devices = CFSetCreateMutable(NULL, 0, NULL);
    fake_init(&receiver, "USB Receiver"); fake_init(&collection, "USB Receiver");
    fake_init(&mouse, "MX Master 3S");
    receiver.names[1] = collection.names[1] = "Logitech MX Keys S Keyboard";
    receiver.names[2] = collection.names[2] = "MX Master 3S";
    receiver.units[1] = collection.units[1] = 1;
    receiver.units[2] = collection.units[2] = 2;
    mouse.names[0] = "MX Master 3S"; mouse.units[0] = 3;
    device_set_t set;
    if (find_devices(&set, 1, 0, NULL, 0) != 3 || set.info[0].rank >= 20) {
        printf("FAIL: discovery did not retain all physical devices/mouse preference\n"); fails++;
    }
    status_t st;
    gather_status(set.devs[0], &set.info[0], 1, &st);
    if (st.battery != 88 || !st.charging || strcmp(st.firmware, "12.34.BABCD")) {
        printf("FAIL: status did not read battery/main firmware protocol\n"); fails++;
    }
    devices_release(&set);
    if (receiver.close_count != 1 || collection.close_count != 1 || mouse.close_count != 1) {
        printf("FAIL: shared handles were not closed exactly once\n"); fails++;
    }
    const char *filters[] = { "Keys" };
    if (find_devices(&set, 1, 0, filters, 1) != 1 || strcmp(set.info[0].name, receiver.names[1])) {
        printf("FAIL: peripheral name filter/fragment lookup\n"); fails++;
    }
    devices_release(&set);
    if (find_devices(&set, 0, 0, NULL, 0) != 1 || set.info[0].rank >= 20) {
        printf("FAIL: primary selection\n"); fails++;
    }
    devices_release(&set);
    CFRelease(receiver.properties); CFRelease(collection.properties); CFRelease(mouse.properties);
    CFRelease(fake_devices);
}

int main(void) {
    for (size_t i = 0; i < sizeof(fixture_frames)/sizeof(fixture_frames[0]); i++) {
        const struct fixture_frame *f = &fixture_frames[i];
        check_frame(f->name, f->rid, f->didx, f->fidx, f->function, f->params, f->count, f->hex);
    }
    /* Oversized and unknown report ids must be rejected. */
    {
        uint8_t big[16] = { 0 };
        if (frame_build(REPORT_SHORT, 0xFF, 0, 0, big, 16, big) != 0) {
            printf("FAIL: oversize short frame accepted\n"); fails++;
        }
        if (frame_build(0x12, 0xFF, 0, 0, NULL, 0, big) != 0) {
            printf("FAIL: unknown report id accepted\n"); fails++;
        }
    }

    for (size_t i = 0; i < sizeof(fixture_replies)/sizeof(fixture_replies[0]); i++) {
        const struct fixture_reply *r = &fixture_replies[i];
        int expected = !strcmp(r->outcome, "match") ? REPLY_MATCH :
                       !strcmp(r->outcome, "error") ? REPLY_ERROR :
                       !strcmp(r->outcome, "too_short") ? REPLY_TOO_SHORT : REPLY_IGNORE;
        check_reply(r->name, r->hex, r->didx, r->fidx, r->function, expected);
    }

    check_config();
    check_name();
    check_discovery();

    if (fails) {
        printf("\n%d test(s) failed\n", fails);
        return 1;
    }
    printf("C tests passed\n");
    return 0;
}
