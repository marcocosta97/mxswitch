# mxswitch

Switch a Logitech Easy-Switch device — MX Master 3S, MX Keys, MX Anywhere and
friends — between paired computers with a keyboard shortcut, without reaching
for the button on the underside and without running Logitech Options+.

Four independent implementations, one per platform. The native ones need **no
third-party dependencies**; the Python port needs `hidapi` except on Windows:

| Platform | File | Needs |
|---|---|---|
| macOS | `macos/mxswitch.c` | `clang` (Command Line Tools) |
| Windows | `windows/mxswitch.ps1` | PowerShell 5.1+ |
| Linux | `linux/mxswitch.sh` | bash, coreutils, a udev rule |
| any | `python/mxswitch.py` | Python 3; `hidapi` except on Windows |

Pick one. They are not layered on each other — each is a standalone file
implementing the same protocol against its platform's native HID API. When both
a mouse and a keyboard are present, the mouse is preferred; use Options+ / Flow
(or `input-switcher`) to move a pair together.

## Why this exists

Easy-Switch devices pair with up to three hosts but only expose channel
switching through a recessed button underneath the device. Logitech's own
software-side answer is Flow, which needs both machines on a network path that
can see each other — frequently blocked by corporate VPN or DLP policy. Options+
can bind Easy-Switch to a button or the Actions Ring, but that requires running
Options+ on every machine, and the Actions Ring is missing from some builds.

Underneath all of it is a single documented HID++ command. `mxswitch` sends that
command and nothing else.

## How it works

Logitech peripherals speak **HID++**, a request/response protocol tunnelled over
a vendor-defined HID collection alongside the normal mouse and keyboard reports.
Feature `0x1814` is `ChangeHost`; its function 1, `setCurrentHost`, takes a
zero-based host index and moves the device to that channel.

A request is 7 bytes (short) or 20 bytes (long):

```
byte 0    report id      0x10 short, 0x11 long
byte 1    device index   0xFF direct (Bluetooth/USB), 1..6 behind a receiver
byte 2    feature index  position of 0x1814 in this device's feature table
byte 3    (function << 4) | software id
byte 4+   parameters
```

Two details matter more than they look:

**The feature index is not the feature ID.** `0x1814` identifies the feature;
where it sits in a given device's table is firmware-specific. Hardcoding an
index works until a firmware update quietly moves it, after which you are
sending `setCurrentHost` to whatever feature now occupies that slot. Every
implementation here queries the root feature at runtime to resolve it.

**A successful `setCurrentHost` never replies.** By the time the device would
answer, it has already dropped off this host. Silence is success.

## The asymmetry worth understanding

A channel switch is always initiated from the machine the device is *currently*
connected to. An idle computer cannot summon the mouse; the active host tells the
device to leave. So `mxswitch` must be installed on **every** machine you want to
switch away from, each configured to send the device to the *other* one.

The practical consequence: if you switch to a channel whose host is asleep, off,
or has Bluetooth disabled, the device parks on a dead channel and the button
underneath is your only way back. Keep the target awake, or pair it via a
receiver, which stays live whenever the machine is powered.

## Install

Run from the tree, or install into a user prefix. Nothing needs a system-wide
`sudo make install` except the one-time Linux udev rule.

### macOS

```sh
make                 # builds and ad-hoc signs ./mxswitch
./mxswitch --info
```

To put it on your PATH without sudo:

```sh
make install PREFIX="$HOME/.local"
# → ~/.local/bin/mxswitch   (ensure ~/.local/bin is on PATH)
# Opens Input Monitoring settings if this binary is not already allowed.
```

Grant **Input Monitoring** in System Settings → Privacy & Security, both to the
binary and to whatever launches it. `make install` runs `mxswitch --setup`,
which skips the Settings pane when TCC already allows this binary.

The `codesign -s -` step in the Makefile is not cosmetic. TCC identifies
unsigned binaries by path *and* code hash, so an unsigned build silently loses
its Input Monitoring grant on every rebuild.

### Windows

```powershell
.\windows\mxswitch.ps1 -Info
.\windows\mxswitch.ps1 -Channel 2
```

No admin rights needed: the vendor-defined collection is not the exclusively
claimed mouse collection, so a normal user can open it.

If the execution policy objects:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\mxswitch.ps1 -Channel 2
```

### Linux

One-time: allow your user to open Logitech hidraw devices (this is the only
step that needs root):

```sh
sudo cp linux/42-logitech-hidpp.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Then run from the tree, or install into a user prefix:

```sh
./linux/mxswitch.sh --info
# or:
install -m 755 linux/mxswitch.sh ~/.local/bin/mxswitch
mxswitch --info
```

### Python (any platform)

```sh
pip install hidapi        # not needed on Windows
python python/mxswitch.py --info
```

On Windows the Python version drives `hid.dll` and `setupapi.dll` through
`ctypes` and needs no packages at all. Elsewhere it falls back to `hidapi`.

## Binding a shortcut

**Windows** — `windows/mxswitch.ahk` (AutoHotkey v2). Edit the three paths at the
top and drop a shortcut to it in `shell:startup`. It also binds a variant that
switches *and* locks the workstation, which is the one worth using day to day.
AHK hotkeys do not fire on the lock screen, so trigger the return switch from the
other machine rather than expecting to wake Windows and press the key.

**macOS** — BetterTouchTool: keyboard shortcut trigger → *Execute Terminal
Command / Shell Script (async, non-blocking)* → e.g.
`$HOME/.local/bin/mxswitch 2` or the absolute path to `./mxswitch` in this
repo. Raycast script commands and Automator Quick Actions work the same way.

**Linux** — GNOME Settings → Keyboard → Custom Shortcuts, or the KDE equivalent,
pointing at e.g. `$HOME/.local/bin/mxswitch 2`.

## Prior art

This is not the first tool to send `ChangeHost`, and if one of these fits you
better, use it:

- [marcelhoffs/input-switcher](https://github.com/marcelhoffs/input-switcher) —
  Windows/Linux scripts around a vendored `hidapitester`; switches a keyboard and
  mouse together, which `mxswitch` does not — it prefers the mouse when both are
  present (use Options+ / Flow to move a pair).
- [meliksah/lcs](https://github.com/meliksah/lcs) — GUI channel switcher.
- [omar16100/logi_mx_auto_switch](https://github.com/omar16100/logi_mx_auto_switch) —
  makes a mouse follow its keyboard automatically on macOS.
- [boyvanamstel/SwitchMX](https://github.com/boyvanamstel/SwitchMX) — macOS, MX Master 3S.
- [Solaar](https://github.com/pwr-Solaar/Solaar) and
  [Mouser](https://github.com/TomBadash/Mouser) — full Options+ replacements that
  cover `ChangeHost` among much else.

What is different here: no vendored binaries anywhere, one self-contained file
per platform, and runtime feature-index discovery rather than hardcoded offsets.


## License

MIT. See `LICENSE`.
