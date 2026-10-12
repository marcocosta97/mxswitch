/* Regression: replies from the mouse must not replace keyboard replies. */
#define main mxswitch_program_main
#include "../macos/mxswitch.c"
#undef main
#include <assert.h>

int main(void) {
    int mouse_token, keyboard_token;
    IOHIDDeviceRef mouse = (IOHIDDeviceRef)&mouse_token;
    IOHIDDeviceRef keyboard = (IOHIDDeviceRef)&keyboard_token;
    uint8_t mouse_report[] = {0x11, 0xff, 0x0a, 0x0a, 3, 1};
    uint8_t keyboard_report[] = {0x11, 0xff, 0x0a, 0x0a, 3, 0};
    g_expected_device = keyboard;
    g_got_reply = 0;
    input_cb(mouse, kIOReturnSuccess, mouse, kIOHIDReportTypeInput,
             0x11, mouse_report, sizeof(mouse_report));
    assert(!g_got_reply);
    input_cb(keyboard, kIOReturnSuccess, keyboard, kIOHIDReportTypeInput,
             0x11, keyboard_report, sizeof(keyboard_report));
    assert(g_got_reply && g_reply[5] == 0);
    input_cb(mouse, kIOReturnSuccess, mouse, kIOHIDReportTypeInput,
             0x11, mouse_report, sizeof(mouse_report));
    assert(g_reply[5] == 0);
    target_t first = {0}, second = {0};
    first.rxbuf = calloc(64, 1);
    second.rxbuf = calloc(64, 1);
    assert(first.rxbuf && second.rxbuf && first.rxbuf != second.rxbuf);
    target_release(&first);
    target_release(&second);
    assert(!first.rxbuf && !second.rxbuf);
    puts("Independent device replies and buffer cleanup passed.");
    return 0;
}
