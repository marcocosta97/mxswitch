/*
 * Hardware-free tests for macos/mxswitch.c.
 *
 * The implementation is compiled into this translation unit with MXSWITCH_TEST
 * set, so main() there is skipped and the static frame helpers are reachable.
 *
 *   cc -O2 -Wall -o /tmp/test_c tests/test_c.c \
 *       -framework IOKit -framework CoreFoundation -framework CoreGraphics
 *   /tmp/test_c
 */

#ifndef MXSWITCH_TEST
#define MXSWITCH_TEST
#endif

#include "../macos/mxswitch.c"

static int fails;

static void hex_of(const uint8_t *b, size_t n, char *out) {
    for (size_t i = 0; i < n; i++) sprintf(out + i * 2, "%02x", b[i]);
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
                        uint8_t dev_idx, uint8_t feature_idx, int expected) {
    uint8_t reply[64];
    size_t n = strlen(hex) / 2;
    for (size_t i = 0; i < n; i++) {
        unsigned v;
        sscanf(hex + i * 2, "%2x", &v);
        reply[i] = (uint8_t)v;
    }
    int got = classify_reply(reply, n, dev_idx, feature_idx);
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

int main(void) {
    const uint8_t feature[3] = { 0x18, 0x14, 0x00 };
    const uint8_t empty[1] = { 0 };
    const uint8_t one[1] = { 1 };
    const uint8_t zero[1] = { 0 };

    check_frame("root getFeature long", REPORT_LONG, 0xFF, 0, 0,
                feature, 3, "11ff000a18140000000000000000000000000000");
    check_frame("root getFeature short", REPORT_SHORT, 0xFF, 0, 0,
                feature, 3, "10ff000a181400");
    check_frame("getHostInfo long", REPORT_LONG, 0xFF, 0x0A, 0,
                empty, 0, "11ff0a0a00000000000000000000000000000000");
    check_frame("getHostInfo short", REPORT_SHORT, 0xFF, 0x0A, 0,
                empty, 0, "10ff0a0a000000");
    check_frame("setCurrentHost(1) long", REPORT_LONG, 0xFF, 0x0A, 1,
                one, 1, "11ff0a1a01000000000000000000000000000000");
    check_frame("setCurrentHost(1) short", REPORT_SHORT, 0xFF, 0x0A, 1,
                one, 1, "10ff0a1a010000");
    check_frame("receiver slot 2", REPORT_LONG, 2, 0x0A, 1,
                zero, 1, "11020a1a00000000000000000000000000000000");

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

    check_reply("match getHostInfo",
                "11ff0a0a03010000000000000000000000000000", 0xFF, 0x0A, REPLY_MATCH);
    check_reply("match root getFeature",
                "11ff000a0a000400000000000000000000000000", 0xFF, 0x00, REPLY_MATCH);
    check_reply("match battery",
                "11ff050a58010000000000000000000000000000", 0xFF, 0x05, REPLY_MATCH);
    check_reply("notification ignored",
                "11ff050a00000000000000000000000000000000", 0xFF, 0x0A, REPLY_IGNORE);
    check_reply("other device ignored",
                "11010a0a03010000000000000000000000000000", 0xFF, 0x0A, REPLY_IGNORE);
    check_reply("other sw id ignored",
                "11ff0a1b03010000000000000000000000000000", 0xFF, 0x0A, REPLY_IGNORE);
    check_reply("HID++ 2.0 error",
                "11ffff0a00000000000000000000000000000000", 0xFF, 0x0A, REPLY_ERROR);
    check_reply("HID++ 1.0 error",
                "11ff8f0a00000000000000000000000000000000", 0xFF, 0x0A, REPLY_ERROR);
    check_reply("too short", "11ff0a", 0xFF, 0x0A, REPLY_TOO_SHORT);

    check_config();
    check_name();

    if (fails) {
        printf("\n%d test(s) failed\n", fails);
        return 1;
    }
    printf("C tests passed\n");
    return 0;
}
