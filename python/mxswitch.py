#!/usr/bin/env python3
"""
mxswitch.py - switch a Logitech Easy-Switch device (MX Master 3S, MX Keys, ...)
to another channel via HID++ 2.0 feature 0x1814 (ChangeHost).

On Windows this needs nothing but a Python 3 interpreter: the HID plumbing goes
straight through hid.dll and setupapi.dll via ctypes. No admin rights - the
vendor-defined collection is not the exclusively-claimed mouse collection.

On macOS/Linux it falls back to hidapi (pip install hidapi), since there is no
equivalent always-present C API to lean on.

    python mxswitch.py --info        # show channels and which one is active
    python mxswitch.py --status      # --info plus battery
    python mxswitch.py 2             # switch to channel 2
    python mxswitch.py --all 2       # switch every ChangeHost device
    python mxswitch.py --toggle      # switch to the other configured channel
    python mxswitch.py --list        # dump candidate HID interfaces

Exit codes: 0 ok, 1 device not found, 2 bad usage, 3 partial --all failure.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

LOGITECH_VID = 0x046D
SW_ID = 0x0A                  # software id, any value 1..15
ROOT_FEATURE = 0x00
FEAT_CHANGE_HOST = 0x1814
FEAT_DEVICE_FW = 0x0003       # DEVICE_FW_VERSION, for --status
FEAT_BATTERY_UNIFIED = 0x1004  # UNIFIED_BATTERY
FEAT_BATTERY_LEVEL = 0x1000    # BATTERY_LEVEL_STATUS

SHORT, LONG = 0x10, 0x11      # HID++ report ids
FRAME_LEN = {SHORT: 7, LONG: 20}

# 0xFF for a directly-connected device (Bluetooth/USB), 1..6 via a receiver.
DEVICE_INDICES = (0xFF, 1, 2, 3, 4, 5, 6)

DEFAULT_CONFIG = {"channel_a": 1, "channel_b": 2, "device": "primary"}


# ---------------------------------------------------------------------------
# Frame construction and reply classification (pure, hardware-free)
# ---------------------------------------------------------------------------

def build_frame(report_id, dev_idx, feature_idx, function, params=b"", sw_id=SW_ID):
    """Encode one HID++ request and zero-pad it to the report's frame length."""
    if report_id not in FRAME_LEN:
        raise ValueError(f"unknown report id {report_id:#x}")
    frame = bytes([report_id, dev_idx, feature_idx, (function << 4) | sw_id]) + bytes(params)
    if len(frame) > FRAME_LEN[report_id]:
        raise ValueError(f"frame too long for report {report_id:#x}")
    return frame.ljust(FRAME_LEN[report_id], b"\x00")


def classify_reply(reply, dev_idx, feature_idx, sw_id=SW_ID):
    """Match the reply-filtering rules documented in docs/protocol.md.

    Returns one of: "too_short", "ignore", "error", "match".
    """
    if len(reply) < 5:
        return "too_short"
    if reply[1] != dev_idx:
        return "ignore"
    if reply[2] in (0xFF, 0x8F):      # HID++ 2.0 / 1.0 error reply
        return "error"
    if reply[2] != feature_idx:
        return "ignore"               # unsolicited notification
    if (reply[3] & 0x0F) != sw_id:
        return "ignore"
    return "match"


def device_rank(usage_page, usage, name):
    """Lower = try first. Mice before keyboards; vendor pages before others."""
    name = (name or "").lower()
    mouse = ((usage_page == 0x0001 and usage == 0x0002)
             or any(w in name for w in ("master", "anywhere", "mouse", "ergo")))
    kbd = ((usage_page == 0x0001 and usage == 0x0006)
           or any(w in name for w in ("keys", "keyboard")))
    tier = 2 if (kbd and not mouse) else (0 if mouse else 1)
    non_vendor = 0 if usage_page >= 0xFF00 else 1
    return tier * 10 + non_vendor


# ---------------------------------------------------------------------------
# Windows backend: ctypes over the Win32 HID API. No third-party packages.
# ---------------------------------------------------------------------------

if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    setupapi = ctypes.WinDLL("setupapi", use_last_error=True)
    hid_dll = ctypes.WinDLL("hid", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    DIGCF_PRESENT, DIGCF_DEVICEINTERFACE = 0x02, 0x10
    GENERIC_READ, GENERIC_WRITE = 0x80000000, 0x40000000
    FILE_SHARE_READ, FILE_SHARE_WRITE = 0x01, 0x02
    OPEN_EXISTING, FILE_FLAG_OVERLAPPED = 3, 0x40000000
    INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
    ERROR_IO_PENDING, WAIT_OBJECT_0 = 997, 0
    HIDP_STATUS_SUCCESS = 0x00110000

    class GUID(ctypes.Structure):
        _fields_ = [("Data1", wintypes.DWORD), ("Data2", wintypes.WORD),
                    ("Data3", wintypes.WORD), ("Data4", ctypes.c_ubyte * 8)]

    class SP_DEVICE_INTERFACE_DATA(ctypes.Structure):
        _fields_ = [("cbSize", wintypes.DWORD), ("InterfaceClassGuid", GUID),
                    ("Flags", wintypes.DWORD), ("Reserved", ctypes.c_void_p)]

    class SP_DEVICE_INTERFACE_DETAIL_DATA_W(ctypes.Structure):
        _fields_ = [("cbSize", wintypes.DWORD), ("DevicePath", ctypes.c_wchar * 512)]

    class HIDD_ATTRIBUTES(ctypes.Structure):
        _fields_ = [("Size", wintypes.ULONG), ("VendorID", wintypes.USHORT),
                    ("ProductID", wintypes.USHORT), ("VersionNumber", wintypes.USHORT)]

    class HIDP_CAPS(ctypes.Structure):
        _fields_ = [("Usage", wintypes.USHORT), ("UsagePage", wintypes.USHORT),
                    ("InputReportByteLength", wintypes.USHORT),
                    ("OutputReportByteLength", wintypes.USHORT),
                    ("FeatureReportByteLength", wintypes.USHORT),
                    ("Reserved", wintypes.USHORT * 17),
                    ("NumberLinkCollectionNodes", wintypes.USHORT),
                    ("NumberInputButtonCaps", wintypes.USHORT),
                    ("NumberInputValueCaps", wintypes.USHORT),
                    ("NumberInputDataIndices", wintypes.USHORT),
                    ("NumberOutputButtonCaps", wintypes.USHORT),
                    ("NumberOutputValueCaps", wintypes.USHORT),
                    ("NumberOutputDataIndices", wintypes.USHORT),
                    ("NumberFeatureButtonCaps", wintypes.USHORT),
                    ("NumberFeatureValueCaps", wintypes.USHORT),
                    ("NumberFeatureDataIndices", wintypes.USHORT)]

    class OVERLAPPED(ctypes.Structure):
        _fields_ = [("Internal", ctypes.c_void_p), ("InternalHigh", ctypes.c_void_p),
                    ("Offset", wintypes.DWORD), ("OffsetHigh", wintypes.DWORD),
                    ("hEvent", wintypes.HANDLE)]

    # Prototypes for every call that takes or returns a handle. Without
    # argtypes, ctypes converts a bare Python int to C int, truncating a
    # 64-bit handle (and raising OverflowError on Windows once it exceeds
    # 2**31) - exactly the hazard the restype-only version missed.
    setupapi.SetupDiGetClassDevsW.restype = wintypes.HANDLE
    setupapi.SetupDiGetClassDevsW.argtypes = [ctypes.POINTER(GUID), wintypes.LPCWSTR,
                                              wintypes.HWND, wintypes.DWORD]
    setupapi.SetupDiEnumDeviceInterfaces.restype = wintypes.BOOL
    setupapi.SetupDiEnumDeviceInterfaces.argtypes = [
        wintypes.HANDLE, ctypes.c_void_p, ctypes.POINTER(GUID),
        wintypes.DWORD, ctypes.POINTER(SP_DEVICE_INTERFACE_DATA)]
    setupapi.SetupDiGetDeviceInterfaceDetailW.restype = wintypes.BOOL
    setupapi.SetupDiGetDeviceInterfaceDetailW.argtypes = [
        wintypes.HANDLE, ctypes.POINTER(SP_DEVICE_INTERFACE_DATA),
        ctypes.POINTER(SP_DEVICE_INTERFACE_DETAIL_DATA_W), wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
    setupapi.SetupDiDestroyDeviceInfoList.restype = wintypes.BOOL
    setupapi.SetupDiDestroyDeviceInfoList.argtypes = [wintypes.HANDLE]

    hid_dll.HidD_GetHidGuid.restype = None
    hid_dll.HidD_GetHidGuid.argtypes = [ctypes.POINTER(GUID)]
    hid_dll.HidD_GetAttributes.restype = wintypes.BOOL
    hid_dll.HidD_GetAttributes.argtypes = [wintypes.HANDLE,
                                           ctypes.POINTER(HIDD_ATTRIBUTES)]
    hid_dll.HidD_GetPreparsedData.restype = wintypes.BOOL
    hid_dll.HidD_GetPreparsedData.argtypes = [wintypes.HANDLE,
                                              ctypes.POINTER(ctypes.c_void_p)]
    hid_dll.HidD_FreePreparsedData.restype = wintypes.BOOL
    hid_dll.HidD_FreePreparsedData.argtypes = [ctypes.c_void_p]
    hid_dll.HidD_GetProductString.restype = wintypes.BOOL
    hid_dll.HidD_GetProductString.argtypes = [wintypes.HANDLE,
                                              ctypes.POINTER(ctypes.c_wchar),
                                              wintypes.ULONG]
    hid_dll.HidP_GetCaps.restype = wintypes.LONG
    hid_dll.HidP_GetCaps.argtypes = [ctypes.c_void_p, ctypes.POINTER(HIDP_CAPS)]

    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                     ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                                     wintypes.HANDLE]
    kernel32.CreateEventW.restype = wintypes.HANDLE
    kernel32.CreateEventW.argtypes = [ctypes.c_void_p, wintypes.BOOL,
                                      wintypes.BOOL, wintypes.LPCWSTR]
    kernel32.CloseHandle.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel32.CancelIo.restype = wintypes.BOOL
    kernel32.CancelIo.argtypes = [wintypes.HANDLE]
    kernel32.GetOverlappedResult.restype = wintypes.BOOL
    kernel32.GetOverlappedResult.argtypes = [
        wintypes.HANDLE, ctypes.POINTER(OVERLAPPED),
        ctypes.POINTER(wintypes.DWORD), wintypes.BOOL]
    kernel32.ResetEvent.restype = wintypes.BOOL
    kernel32.ResetEvent.argtypes = [wintypes.HANDLE]
    kernel32.WriteFile.restype = wintypes.BOOL
    kernel32.WriteFile.argtypes = [
        wintypes.HANDLE, ctypes.POINTER(ctypes.c_char), wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(OVERLAPPED)]
    kernel32.ReadFile.restype = wintypes.BOOL
    kernel32.ReadFile.argtypes = kernel32.WriteFile.argtypes

    def _query(path):
        """Open briefly, read VID/usage/report lengths, close. None if unusable."""
        h = kernel32.CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                 None, OPEN_EXISTING, 0, None)
        if h == INVALID_HANDLE_VALUE:
            return None
        try:
            attrs = HIDD_ATTRIBUTES()
            attrs.Size = ctypes.sizeof(attrs)
            if not hid_dll.HidD_GetAttributes(h, ctypes.byref(attrs)):
                return None
            if attrs.VendorID != LOGITECH_VID:
                return None

            pp = ctypes.c_void_p()
            if not hid_dll.HidD_GetPreparsedData(h, ctypes.byref(pp)):
                return None
            try:
                caps = HIDP_CAPS()
                if hid_dll.HidP_GetCaps(pp, ctypes.byref(caps)) != HIDP_STATUS_SUCCESS:
                    return None
            finally:
                hid_dll.HidD_FreePreparsedData(pp)

            if caps.UsagePage < 0xFF00:
                return None                # not a vendor-defined collection
            if caps.OutputReportByteLength == 0:
                return None                # nothing writable here

            name = ctypes.create_unicode_buffer(128)
            hid_dll.HidD_GetProductString(h, name, ctypes.sizeof(name))
            return {"path": path, "usage_page": caps.UsagePage, "usage": caps.Usage,
                    "product_id": attrs.ProductID, "product_string": name.value,
                    "in_len": caps.InputReportByteLength,
                    "out_len": caps.OutputReportByteLength}
        finally:
            kernel32.CloseHandle(h)

    def enumerate_interfaces():
        guid = GUID()
        hid_dll.HidD_GetHidGuid(ctypes.byref(guid))
        hdev = setupapi.SetupDiGetClassDevsW(ctypes.byref(guid), None, None,
                                             DIGCF_PRESENT | DIGCF_DEVICEINTERFACE)
        if hdev == INVALID_HANDLE_VALUE:
            return
        found = []
        try:
            iface = SP_DEVICE_INTERFACE_DATA()
            iface.cbSize = ctypes.sizeof(iface)
            index = 0
            while setupapi.SetupDiEnumDeviceInterfaces(hdev, None, ctypes.byref(guid),
                                                       index, ctypes.byref(iface)):
                index += 1
                detail = SP_DEVICE_INTERFACE_DETAIL_DATA_W()
                # Documented fixed value, NOT sizeof(): 8 on x64, 6 on x86.
                detail.cbSize = 8 if ctypes.sizeof(ctypes.c_void_p) == 8 else 6
                if setupapi.SetupDiGetDeviceInterfaceDetailW(
                        hdev, ctypes.byref(iface), ctypes.byref(detail),
                        ctypes.sizeof(detail), None, None):
                    info = _query(detail.DevicePath)
                    if info:
                        found.append(info)
        finally:
            setupapi.SetupDiDestroyDeviceInfoList(hdev)
        found.sort(key=lambda i: device_rank(i["usage_page"], i["usage"],
                                             i["product_string"]))
        yield from found

    class Device:
        """Overlapped I/O, because a blocking ReadFile on a HID device that has
        nothing to say will simply never return."""

        def __init__(self, info):
            self.in_len, self.out_len = info["in_len"], info["out_len"]
            self.h = kernel32.CreateFileW(
                info["path"], GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, None, OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED, None)
            if self.h == INVALID_HANDLE_VALUE:
                raise OSError(ctypes.get_last_error(), "CreateFileW failed")
            self.event = kernel32.CreateEventW(None, True, False, None)
            if not self.event:
                kernel32.CloseHandle(self.h)
                raise OSError(ctypes.get_last_error(), "CreateEventW failed")

        def _wait(self, ov, timeout_ms):
            transferred = wintypes.DWORD()
            if kernel32.WaitForSingleObject(self.event, timeout_ms) != WAIT_OBJECT_0:
                # Cancel and wait for the aborted IRP to complete before the
                # caller's OVERLAPPED/buffer go out of scope, so a late
                # completion cannot write into freed memory or signal the event
                # for the next operation.
                kernel32.CancelIo(self.h)
                kernel32.GetOverlappedResult(self.h, ctypes.byref(ov),
                                             ctypes.byref(transferred), True)
                return None
            if not kernel32.GetOverlappedResult(self.h, ctypes.byref(ov),
                                                ctypes.byref(transferred), False):
                return None
            return transferred.value

        def write(self, data):
            buf = ctypes.create_string_buffer(
                bytes(data).ljust(self.out_len, b"\x00"), self.out_len)
            ov = OVERLAPPED()
            ov.hEvent = self.event
            kernel32.ResetEvent(self.event)
            if not kernel32.WriteFile(self.h, buf, self.out_len, None, ctypes.byref(ov)):
                if ctypes.get_last_error() != ERROR_IO_PENDING:
                    raise OSError(ctypes.get_last_error(), "WriteFile failed")
                if self._wait(ov, 1000) is None:
                    raise OSError("write timed out")

        def read(self, timeout_ms=100):
            buf = ctypes.create_string_buffer(self.in_len)
            ov = OVERLAPPED()
            ov.hEvent = self.event
            kernel32.ResetEvent(self.event)
            if not kernel32.ReadFile(self.h, buf, self.in_len, None, ctypes.byref(ov)):
                if ctypes.get_last_error() != ERROR_IO_PENDING:
                    return b""
            n = self._wait(ov, timeout_ms)
            return buf.raw[:n] if n else b""

        def close(self):
            kernel32.CloseHandle(self.event)
            kernel32.CloseHandle(self.h)


# ---------------------------------------------------------------------------
# Everything else: hidapi.
# ---------------------------------------------------------------------------

else:
    def _hid():
        # Imported lazily so the pure protocol helpers stay importable (and
        # testable) on machines without hidapi.
        try:
            import hid
        except ImportError:
            sys.exit("On this platform mxswitch needs hidapi:  pip install hidapi")
        return hid

    def enumerate_interfaces():
        # Prefer mice over keyboards when both are present. Prefer vendor-defined
        # collections; also yield others — over Bluetooth on macOS, HID++ often
        # lives on the mouse collection alone.
        seen = set()
        found = []
        for info in _hid().enumerate(LOGITECH_VID, 0):
            if info["path"] in seen:
                continue
            seen.add(info["path"])
            found.append({"path": info["path"], "usage_page": info["usage_page"],
                          "usage": info["usage"], "product_id": info["product_id"],
                          "product_string": info["product_string"],
                          "in_len": FRAME_LEN[LONG], "out_len": 0})
        found.sort(key=lambda i: device_rank(i["usage_page"], i["usage"],
                                             i["product_string"]))
        yield from found

    class Device:
        def __init__(self, info):
            self.out_len = 0                 # hidapi sizes the frame itself
            self.dev = _hid().device()
            try:
                self.dev.open_path(info["path"])
                self.dev.set_nonblocking(0)
            except Exception:
                self.dev.close()
                raise

        def write(self, data):
            self.dev.write(bytes(data))

        def read(self, timeout_ms=100):
            return bytes(self.dev.read(FRAME_LEN[LONG], timeout_ms=timeout_ms))

        def close(self):
            self.dev.close()


# ---------------------------------------------------------------------------
# HID++ protocol
# ---------------------------------------------------------------------------

def request(dev, report_id, dev_idx, feature_idx, function, params=b"", timeout_ms=500):
    """Send one HID++ call and wait for its matching reply. None on timeout/error."""
    dev.write(build_frame(report_id, dev_idx, feature_idx, function, params))

    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() < deadline:
        reply = dev.read(timeout_ms=100)
        outcome = classify_reply(reply, dev_idx, feature_idx)
        if outcome == "match":
            return reply
        if outcome == "error":
            return None
    return None


def resolve_feature(dev, report_id, dev_idx, feature_id):
    """Resolve a feature ID to its runtime table index, or 0 if unsupported."""
    probe = bytes([feature_id >> 8, feature_id & 0xFF, 0x00])
    reply = request(dev, report_id, dev_idx, ROOT_FEATURE, 0, probe, timeout_ms=300)
    return reply[4] if reply else 0


def iter_devices(want_all):
    """Yield discovered ChangeHost-capable devices, mouse first.

    One physical device can expose several collections that all answer the
    probe; only the first matching collection per (product, device index) is
    yielded, so `--all` does not switch the same device twice.
    """
    for info in enumerate_interfaces():
        try:
            dev = Device(info)
        except OSError:
            continue
        report_ids = [r for r in (LONG, SHORT)
                      if not info["out_len"] or FRAME_LEN[r] <= info["out_len"]]
        matched = False
        for dev_idx in DEVICE_INDICES:
            for report_id in report_ids:
                try:
                    reply = request(dev, report_id, dev_idx, ROOT_FEATURE, 0,
                                    bytes([FEAT_CHANGE_HOST >> 8,
                                           FEAT_CHANGE_HOST & 0xFF, 0x00]),
                                    timeout_ms=250)
                except OSError:
                    continue
                if reply and reply[4] != 0x00:
                    matched = True
                    break
            if matched:
                break
        if not matched:
            dev.close()
            continue

        key = ((info["product_string"] or "").lower(), dev_idx)
        if key in iter_devices.seen:
            dev.close()
            continue
        iter_devices.seen.add(key)

        yield dev, dev_idx, report_id, reply[4], info
        if not want_all:
            return


iter_devices.seen = set()


def host_info(dev, dev_idx, report_id, feat_idx):
    reply = request(dev, report_id, dev_idx, feat_idx, 0)
    if reply and len(reply) >= 6:
        return (reply[4], reply[5])
    return None


def battery_status(dev, dev_idx, report_id):
    """(percent, charging) from whichever battery feature the device exposes."""
    for feat_id in (FEAT_BATTERY_UNIFIED, FEAT_BATTERY_LEVEL):
        idx = resolve_feature(dev, report_id, dev_idx, feat_id)
        if not idx:
            continue
        reply = request(dev, report_id, dev_idx, idx, 0, timeout_ms=300)
        if reply and len(reply) >= 6:
            return reply[4], bool(reply[5] & 0x01)
    return None


def firmware_version(dev, dev_idx, report_id):
    """Best-effort main firmware version from DEVICE_FW_VERSION."""
    idx = resolve_feature(dev, report_id, dev_idx, FEAT_DEVICE_FW)
    if not idx:
        return None
    reply = request(dev, report_id, dev_idx, idx, 0, timeout_ms=300)
    if not reply or len(reply) < 8 or reply[4] == 0:
        return None
    major, minor = reply[6], reply[7]
    if major == 0 and minor == 0:
        return None
    return f"{major}.{minor}"


def set_host(dev, dev_idx, report_id, feat_idx, host_0based, dry_run=False):
    """setCurrentHost. Never replies - the link is gone by then."""
    frame = build_frame(report_id, dev_idx, feat_idx, 1, bytes([host_0based]))
    if dry_run:
        return frame
    dev.write(frame)
    return frame


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def config_path():
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return Path(base) / "mxswitch" / "config"


def load_config(path=None):
    """key=value config. Missing file or malformed lines fall back to defaults."""
    cfg = dict(DEFAULT_CONFIG)
    p = Path(path) if path else config_path()
    try:
        text = p.read_text()
    except OSError:
        return cfg
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        key = key.lower()
        if key in ("channel_a", "channel_b"):
            try:
                value = int(value)
            except ValueError:
                continue
        if key in cfg:
            cfg[key] = value
    return cfg


def validate_config(cfg):
    problems = []
    for key in ("channel_a", "channel_b"):
        if cfg[key] not in (1, 2, 3):
            problems.append(f"{key} must be 1, 2 or 3")
    if cfg["channel_a"] == cfg["channel_b"]:
        problems.append("channel_a and channel_b must differ")
    if cfg["device"] not in ("primary", "all"):
        problems.append("device must be primary or all")
    return problems


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def describe_device(dev, dev_idx, report_id, feat_idx, info, status=False):
    data = {
        "product": info["product_string"],
        "device_index": dev_idx,
        "report_id": report_id,
        "feature_index": feat_idx,
        "transport": "direct (BT/USB)" if dev_idx == 0xFF else "receiver",
    }
    hosts = host_info(dev, dev_idx, report_id, feat_idx)
    if hosts:
        data["hosts"] = hosts[0]
        data["channel"] = hosts[1] + 1
    if status:
        battery = battery_status(dev, dev_idx, report_id)
        if battery:
            data["battery_percent"], data["charging"] = battery
        fw = firmware_version(dev, dev_idx, report_id)
        if fw:
            data["firmware"] = fw
    return data


def print_human(data):
    print(f"device     : {data['product']}")
    print(f"transport  : {data['transport']}  index={data['device_index']:#04x}"
          f"  report={data['report_id']:#04x}")
    print(f"ChangeHost : feature index {data['feature_index']:#04x}")
    if "hosts" in data:
        print(f"channels   : {data['hosts']}, currently on {data['channel']}")
    if "battery_percent" in data:
        state = "charging" if data.get("charging") else "discharging"
        print(f"battery    : {data['battery_percent']}% ({state})")
    if "firmware" in data:
        print(f"firmware   : {data['firmware']}")


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(2, f"{self.prog}: error: {message}\n")


def main():
    ap = _Parser(description=__doc__,
                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("channel", nargs="?", type=int,
                    help="target channel, 1-based")
    ap.add_argument("--info", action="store_true", help="show host info and exit")
    ap.add_argument("--status", action="store_true",
                    help="show host info plus battery and firmware")
    ap.add_argument("--list", action="store_true", help="dump HID interfaces and exit")
    ap.add_argument("--all", action="store_true",
                    help="switch every ChangeHost device, not just the preferred one")
    ap.add_argument("--toggle", action="store_true",
                    help="switch to the other channel in the configured pair")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the frames that would be sent, without sending")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--verbose", action="store_true", help="explain what is probed")
    ap.add_argument("--config", metavar="PATH", help="config file path")
    args = ap.parse_args()

    if args.list:
        for i in enumerate_interfaces():
            print(f"{i['usage_page']:#06x}:{i['usage']:#06x}  pid={i['product_id']:#06x}"
                  f"  out={i['out_len']}  {i['product_string']}")
        return 0

    cfg = load_config(args.config)
    problems = validate_config(cfg)

    modes = [args.info, args.status, args.toggle]
    if sum(bool(m) for m in modes) > 1:
        ap.error("--info, --status and --toggle are mutually exclusive")

    want_all = args.all or cfg["device"] == "all"

    if args.toggle and (problems or cfg["channel_a"] == cfg["channel_b"]):
        sys.stderr.write("Cannot toggle: " + "; ".join(problems or
                         ["channel_a and channel_b must differ"]) + "\n")
        return 2
    if not args.info and not args.status and not args.toggle:
        if args.channel is None or not 1 <= args.channel <= 3:
            ap.error("channel must be 1, 2 or 3")

    if args.verbose:
        print(f"config     : {args.config or config_path()}", file=sys.stderr)

    iter_devices.seen.clear()
    devices = list(iter_devices(want_all))
    if not devices:
        print("No Logitech device supporting ChangeHost found.", file=sys.stderr)
        print("Click the mouse once to wake it, then retry. See also --list.",
              file=sys.stderr)
        return 1

    try:
        if args.info or args.status:
            try:
                reports = [describe_device(*d, status=args.status) for d in devices]
            except OSError as exc:
                sys.stderr.write(f"Could not read device status: {exc}\n")
                return 1
            if args.json:
                # Always an array, matching the macOS/Linux/PowerShell ports.
                print(json.dumps(reports, indent=2))
            else:
                for i, report in enumerate(reports):
                    if i:
                        print()
                    print_human(report)
            return 0

        if args.toggle:
            primary = devices[0]
            try:
                hosts = host_info(primary[0], primary[1], primary[2], primary[3])
            except OSError as exc:
                sys.stderr.write(f"Could not read the current channel ({exc}).\n")
                return 1
            if not hosts:
                sys.stderr.write("Could not read the current channel.\n")
                return 1
            current = hosts[1] + 1
            if current == cfg["channel_a"]:
                args.channel = cfg["channel_b"]
            elif current == cfg["channel_b"]:
                args.channel = cfg["channel_a"]
            else:
                sys.stderr.write(
                    f"Current channel {current} is not in the configured pair "
                    f"{cfg['channel_a']},{cfg['channel_b']}. Refusing to guess.\n")
                return 1

        target = args.channel - 1
        if args.dry_run:
            for dev, dev_idx, report_id, feat_idx, info in devices:
                frame = set_host(dev, dev_idx, report_id, feat_idx, target,
                                 dry_run=True)
                print(f"{info['product_string'] or 'device'}: "
                      f"switch to channel {args.channel} -> {frame.hex()}")
            return 0

        print(f"Switching to channel {args.channel} ...")
        failures = []
        for dev, dev_idx, report_id, feat_idx, info in devices:
            try:
                set_host(dev, dev_idx, report_id, feat_idx, target)
                name = info["product_string"] or "device"
                print(f"  {name}: command sent")
            except OSError as exc:
                failures.append((info["product_string"] or "device", exc))
        for name, exc in failures:
            sys.stderr.write(f"  {name}: failed ({exc})\n")

        if failures and len(failures) == len(devices):
            return 1
        if failures:
            sys.stderr.write(f"{len(failures)} of {len(devices)} devices failed.\n")
            return 3
        return 0
    finally:
        for dev, *_rest in devices:
            dev.close()


if __name__ == "__main__":
    sys.exit(main())
