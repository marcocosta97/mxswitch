"""Protocol and CLI tests for python/mxswitch.py.

Run:  python3 -m unittest discover -s tests -p 'test_python.py'
These cover the hardware-free paths: frame encoding, reply classification,
config parsing, and the --toggle / --all / --dry-run decision logic with a
fake transport. A real switch still needs real hardware.
"""

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_module():
    path = os.path.join(ROOT, "python", "mxswitch.py")
    spec = importlib.util.spec_from_file_location("mxswitch", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["mxswitch"] = module
    spec.loader.exec_module(module)
    return module


mx = load_module()
with open(os.path.join(ROOT, "tests", "fixtures", "frames.json")) as _fh:
    FIXTURES = json.load(_fh)


class FakeDevice:
    def __init__(self):
        self.writes = []
        self.closed = False

    def write(self, data):
        self.writes.append(bytes(data))

    def read(self, timeout_ms=100):
        return b""

    def close(self):
        self.closed = True


def fake_entry(index=0, name=None):
    dev = FakeDevice()
    info = {"product_string": name if name is not None else f"MX Master {index}",
            "product_id": 0x0001, "usage_page": 0xFF00, "usage": 0x0001,
            "path": f"/dev/fake{index}", "in_len": 20, "out_len": 20}
    return (dev, 0xFF, 0x11, 0x0A, info)


class FrameTests(unittest.TestCase):
    def test_encoding_matches_fixtures(self):
        for f in FIXTURES["frames"]:
            with self.subTest(f["name"]):
                got = mx.build_frame(f["report_id"], f["device_index"],
                                     f["feature_index"], f["function"],
                                     bytes(f["params"])).hex()
                self.assertEqual(got, f["hex"])

    def test_reply_classification_matches_fixtures(self):
        for r in FIXTURES["replies"]:
            with self.subTest(r["name"]):
                got = mx.classify_reply(bytes.fromhex(r["hex"]),
                                        r["device_index"], r["feature_index"],
                                        function=r.get("function", 0))
                self.assertEqual(got, r["outcome"])

    def test_rejects_bad_report_id(self):
        with self.assertRaises(ValueError):
            mx.build_frame(0x12, 0xFF, 0, 0)

    def test_rejects_oversized_frame(self):
        with self.assertRaises(ValueError):
            mx.build_frame(0x10, 0xFF, 0, 0, b"\x00" * 10)

    def test_set_host_dry_run_does_not_write(self):
        dev = FakeDevice()
        frame = mx.set_host(dev, 0xFF, 0x11, 0x0A, 1, dry_run=True)
        self.assertEqual(dev.writes, [])
        self.assertEqual(frame.hex(), "11ff0a1a01000000000000000000000000000000")

    def test_set_host_writes_long_frame(self):
        dev = FakeDevice()
        mx.set_host(dev, 0xFF, 0x11, 0x0A, 1)
        self.assertEqual(len(dev.writes), 1)
        self.assertEqual(dev.writes[0][:5], bytes([0x11, 0xFF, 0x0A, 0x1A, 0x01]))


class ConfigTests(unittest.TestCase):
    def test_defaults_when_file_missing(self):
        cfg = mx.load_config("/nonexistent/mxswitch/config")
        self.assertEqual(cfg, mx.DEFAULT_CONFIG)

    def test_parses_values_comments_and_junk(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as fh:
            fh.write("# comment\nchannel_a = 3\n\nbogus\nchannel_b=1\n"
                     "device = all\n")
            path = fh.name
        try:
            cfg = mx.load_config(path)
        finally:
            os.unlink(path)
        self.assertEqual(cfg["channel_a"], 3)
        self.assertEqual(cfg["channel_b"], 1)
        self.assertEqual(cfg["device"], "all")

    def test_parses_name_list(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as fh:
            fh.write("name = MX Keys, MX Master 3S ,\n")
            path = fh.name
        try:
            cfg = mx.load_config(path)
        finally:
            os.unlink(path)
        # Internal spaces kept, blanks dropped.
        self.assertEqual(cfg["name"], ["MX Keys", "MX Master 3S"])

    def test_validation_catches_bad_values(self):
        bad = {"channel_a": 1, "channel_b": 1, "device": "all"}
        self.assertIn("channel_a and channel_b must differ",
                      mx.validate_config(bad))
        bad = {"channel_a": 1, "channel_b": 4, "device": "all"}
        self.assertTrue(mx.validate_config(bad))
        bad = {"channel_a": 1, "channel_b": 2, "device": "nope"}
        self.assertTrue(mx.validate_config(bad))


class ProductNameTests(unittest.TestCase):
    def test_keeps_a_real_product_string(self):
        self.assertEqual(mx.product_name("MX Keys S", 0x1234), "MX Keys S")

    def test_pop_icon_keys_fallback(self):
        self.assertEqual(mx.product_name("", mx.POP_ICON_KEYS_BT_PID), "POP Icon Keys")

    def test_other_unnamed_device_stays_empty(self):
        self.assertEqual(mx.product_name("", 0x1234), "")


class NameFilterTests(unittest.TestCase):
    def test_no_filter_matches_everything(self):
        self.assertTrue(mx.name_matches(fake_entry()[4], None))
        self.assertTrue(mx.name_matches(fake_entry()[4], []))

    def test_case_insensitive_substring(self):
        info = fake_entry(name="MX Keys S")[4]
        self.assertTrue(mx.name_matches(info, ["keys"]))
        self.assertTrue(mx.name_matches(info, ["KEY"]))
        self.assertFalse(mx.name_matches(info, ["master"]))

    def test_any_filter_matches(self):
        info = fake_entry(name="MX Master 3S")[4]
        self.assertTrue(mx.name_matches(info, ["nope", "master"]))

    def test_unnamed_device_needs_no_filter(self):
        info = fake_entry(name="")[4]
        self.assertFalse(mx.name_matches(info, ["master"]))
        self.assertTrue(mx.name_matches(info, None))


class CliTests(unittest.TestCase):
    def setUp(self):
        self.orig_iter = mx.iter_devices
        self.orig_host = mx.host_info
        self.config_patch = patch.object(mx, "config_path", return_value=Path("/nonexistent/mxswitch/config"))
        self.config_patch.start()
        self.devices = []
        self.names_seen = None

    def tearDown(self):
        self.config_patch.stop()
        mx.iter_devices = self.orig_iter
        mx.host_info = self.orig_host

    def install(self, entries, host=(3, 0)):
        self.devices = entries

        def fake_iter(want_all, names=None, verbose=False):
            self.names_seen = names
            devs = [e for e in entries if mx.name_matches(e[4], names)]
            if not want_all:
                devs = devs[:1]
            return iter(devs)

        fake_iter.seen = set()
        mx.iter_devices = fake_iter
        mx.host_info = lambda *a, **k: host

    def run_main(self, argv):
        out, err = io.StringIO(), io.StringIO()
        argv_orig = sys.argv
        sys.argv = ["mxswitch"] + argv
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    code = mx.main()
                except SystemExit as exc:
                    code = exc.code if isinstance(exc.code, int) else 2
        finally:
            sys.argv = argv_orig
        return code, out.getvalue(), err.getvalue()

    def test_dry_run_prints_without_writing(self):
        self.install([fake_entry()])
        code, out, _ = self.run_main(["--dry-run", "2"])
        self.assertEqual(code, 0)
        self.assertIn("11ff0a1a01000000000000000000000000000000", out)
        self.assertEqual(self.devices[0][0].writes, [])

    def test_switch_writes_to_primary_only_by_default(self):
        self.install([fake_entry(0), fake_entry(1)])
        code, out, _ = self.run_main(["2"])
        self.assertEqual(code, 0)
        self.assertEqual(len(self.devices[0][0].writes), 1)
        self.assertEqual(self.devices[1][0].writes, [])

    def test_all_switch_writes_to_every_device(self):
        self.install([fake_entry(0), fake_entry(1)])
        code, _, _ = self.run_main(["--all", "2"])
        self.assertEqual(code, 0)
        self.assertEqual(len(self.devices[0][0].writes), 1)
        self.assertEqual(len(self.devices[1][0].writes), 1)

    def test_all_partial_failure_exits_3(self):
        entries = [fake_entry(0), fake_entry(1)]

        def boom(data):
            raise OSError("nope")

        entries[1][0].write = boom
        self.install(entries)
        code, _, err = self.run_main(["--all", "2"])
        self.assertEqual(code, 3)
        self.assertIn("1 of 2 devices failed", err)

    def test_toggle_picks_the_other_channel(self):
        self.install([fake_entry()], host=(3, 0))  # currently channel 1
        code, out, _ = self.run_main(["--toggle"])
        self.assertEqual(code, 0)
        # channel_b (2) is the target -> host index 1
        self.assertEqual(self.devices[0][0].writes[0][4], 1)
        self.assertIn("Switching to channel 2", out)

    def test_toggle_from_other_channel(self):
        self.install([fake_entry()], host=(3, 1))  # currently channel 2
        code, _, _ = self.run_main(["--toggle"])
        self.assertEqual(code, 0)
        self.assertEqual(self.devices[0][0].writes[0][4], 0)

    def test_toggle_refuses_unknown_channel(self):
        self.install([fake_entry()], host=(3, 2))  # channel 3, not in pair
        code, _, err = self.run_main(["--toggle"])
        self.assertEqual(code, 1)
        self.assertIn("Refusing to guess", err)

    def test_usage_error_without_channel(self):
        self.install([fake_entry()])
        code, _, _ = self.run_main([])
        self.assertEqual(code, 2)

    def test_json_is_always_an_array(self):
        # Every port emits a JSON array, including the single-device case.
        self.install([fake_entry()])
        code, out, _ = self.run_main(["--info", "--json"])
        self.assertEqual(code, 0)
        self.assertTrue(out.lstrip().startswith("["))
        self.assertIn('"product"', out)

    def test_name_filter_selects_matching_device(self):
        entries = [fake_entry(0, name="MX Master 3S"),
                   fake_entry(1, name="MX Keys S")]
        self.install(entries)
        code, _, _ = self.run_main(["--all", "--name", "keys", "2"])
        self.assertEqual(code, 0)
        self.assertEqual(self.names_seen, ["keys"])
        self.assertEqual(entries[0][0].writes, [])
        self.assertEqual(len(entries[1][0].writes), 1)

    def test_name_filter_without_match_returns_1(self):
        self.install([fake_entry(0, name="MX Master 3S")])
        code, _, err = self.run_main(["2", "--name", "nope"])
        self.assertEqual(code, 1)
        self.assertIn("No Logitech device", err)

    def test_config_name_filter_is_used(self):
        entries = [fake_entry(0, name="MX Master 3S"),
                   fake_entry(1, name="MX Keys S")]
        self.install(entries)
        with tempfile.NamedTemporaryFile("w", delete=False) as fh:
            fh.write("name=keys\n")
            path = fh.name
        try:
            code, _, _ = self.run_main(["--all", "--config", path, "2"])
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        self.assertEqual(self.names_seen, ["keys"])
        self.assertEqual(entries[0][0].writes, [])
        self.assertEqual(len(entries[1][0].writes), 1)

    def test_invalid_numeric_config_is_not_a_default(self):
        with tempfile.NamedTemporaryFile('w', delete=False) as f:
            f.write('channel_a=typo\n')
            path = f.name
        try:
            cfg = mx.load_config(path)
            self.assertEqual(cfg['channel_a'],0)
            code, _, err = self.run_main(['--toggle','--config',path])
            self.assertEqual(code,2)
            self.assertIn(path,err)
        finally:
            os.unlink(path)

    def test_missing_explicit_config_is_an_error(self):
        code, _, _ = self.run_main(['2','--config','/nonexistent/mxswitch/config'])
        self.assertEqual(code,2)

    def test_conflicting_modes_fail_before_discovery(self):
        with patch.object(mx,'enumerate_interfaces',side_effect=AssertionError('must not scan')):
            for args in (['--info','--toggle'],['--list','--toggle'],['2','--info'],['1','2']):
                code, _, _ = self.run_main(args)
                self.assertEqual(code,2,args)

class ProtocolDevice:
    """A receiver/direct peripheral that responds to the actual encoded requests."""
    def __init__(self, info):
        self.info = info
        self.writes = []
        self.pending = []
        self.closed = 0

    def write(self, frame):
        self.writes.append(bytes(frame))
        rid, didx, feature, header = frame[:4]
        function = header >> 4
        profile = self.info['slots'].get(didx)
        reply = bytearray([mx.LONG, didx, feature, header])
        if profile is None:
            reply = bytearray([mx.SHORT, didx, 0xFF, feature, header, 9])
        elif feature == 0:
            requested = int.from_bytes(frame[4:6], 'big')
            idx = {0x1814:10, 0x0005:5, 0x0003:3, 0x1004:6, 0x1000:7}.get(requested, 0)
            if requested == 0x1004 and profile.get('legacy_battery'):
                idx = 0
            reply.extend([idx, 0, 0])
        elif feature == 5:
            name = profile['name'].encode()
            reply.extend(bytes([len(name)]) if function == 0 else name[frame[4]:frame[4]+16])
        elif feature == 3:
            if function == 0:
                reply.extend(bytes([2]) + profile['unit'].to_bytes(4, 'big') + bytes(11))
            else:
                reply.extend(bytes([1 if frame[4] == 0 else 0]) + b'RMP' + bytes([0x12, 0x34, 0xAB, 0xCD]))
        elif feature in (6, 7):
            # Function 0 on unified battery is capabilities, not a percentage.
            payload = [2, 8, 0, 0] if feature == 6 and function == 0 else [88, 80, profile.get('charge', 1), 0]
            reply.extend(payload)
        elif feature == 10:
            reply.extend([3, profile.get('channel', 0)])
        self.pending.append(bytes(reply).ljust(mx.FRAME_LEN[reply[0]], b'\0'))

    def read(self, timeout_ms=100):
        return self.pending.pop(0) if self.pending else b''

    def close(self):
        self.closed += 1


def protocol_info(path, slots, name='USB Receiver'):
    info = fake_entry(name=name)[4]
    return dict(info, path=path, slots=slots)


class DiscoveryTests(unittest.TestCase):
    def discover(self, infos, want_all=True, names=None):
        opened = []
        def open_device(info):
            dev = ProtocolDevice(info)
            opened.append(dev)
            return dev
        with patch.object(mx, 'enumerate_interfaces', return_value=iter(infos)), patch.object(mx, 'Device', side_effect=open_device):
            found = list(mx.iter_devices(want_all, names))
        return found, opened

    def test_all_receiver_slots_and_mouse_preference(self):
        info = protocol_info('receiver', {1:dict(name='MX Keys S', unit=1), 2:dict(name='MX Master 3S', unit=2)})
        found, _ = self.discover([info])
        self.assertEqual([(d[1], d[4]['product_string']) for d in found], [(2,'MX Master 3S'),(1,'MX Keys S')])
        mx.close_devices(found)
        self.assertEqual(found[0][0].closed, 1)
        primary, _ = self.discover([info], False)
        self.assertEqual(primary[0][1], 2)
        self.assertEqual(primary[0][0].closed, 0)
        mx.close_devices(primary)

    def test_filter_uses_peripheral_name_and_reads_fragments(self):
        name = 'Logitech MX Keys S Keyboard'
        info = protocol_info('receiver', {1:dict(name=name, unit=1), 2:dict(name='MX Master 3S', unit=2)})
        found, _ = self.discover([info], names=['Keys'])
        self.assertEqual([d[4]['product_string'] for d in found], [name])
        mx.close_devices(found)

    def test_same_model_is_retained_but_collections_are_deduplicated(self):
        infos = [protocol_info('mouse-a-col1', {255:dict(name='MX Master 3S',unit=1)}, 'MX Master 3S'),
                 protocol_info('mouse-a-col2', {255:dict(name='MX Master 3S',unit=1)}, 'MX Master 3S'),
                 protocol_info('mouse-b', {255:dict(name='MX Master 3S',unit=2)}, 'MX Master 3S')]
        found, opened = self.discover(infos)
        self.assertEqual(len(found), 2)
        self.assertEqual(opened[1].closed, 1)
        mx.close_devices(found)
        self.assertEqual([d.closed for d in opened], [1,1,1])

    def test_no_filter_match_closes_transport(self):
        found, opened = self.discover([protocol_info('mouse', {255:dict(name='Mouse',unit=1)}, 'Mouse')], names=['Keys'])
        self.assertEqual(found, [])
        self.assertEqual(opened[0].closed, 1)

    def test_late_reply_is_ignored_using_rotating_request_id(self):
        dev = ProtocolDevice(protocol_info('mouse', {255:dict(name='Mouse',unit=1)}))
        dev.pending.append(bytes.fromhex('11ff00090f000000000000000000000000000000'))
        self.assertEqual(mx.resolve_feature(dev, mx.LONG, 255, 0x1814), 10)
        self.assertEqual(mx.resolve_feature(dev, mx.LONG, 255, 0x0005), 5)
        self.assertNotEqual(dev.writes[0][3], dev.writes[1][3])


class StatusProtocolTests(unittest.TestCase):
    def test_unified_battery_uses_status_function(self):
        dev = ProtocolDevice(protocol_info('mouse', {255:dict(name='Mouse',unit=1)}))
        self.assertEqual(mx.battery_status(dev,255,mx.LONG),(88,True))
        self.assertEqual(dev.writes[-1][3] >> 4, 1)

    def test_legacy_battery_status_is_not_next_level_bit(self):
        dev = ProtocolDevice(protocol_info('mouse', {255:dict(name='Mouse',unit=1,legacy_battery=True,charge=0)}))
        self.assertEqual(mx.battery_status(dev,255,mx.LONG),(88,False))
        self.assertEqual(dev.writes[-1][3] >> 4, 0)

    def test_firmware_reads_main_entity_after_bootloader(self):
        dev = ProtocolDevice(protocol_info('mouse', {255:dict(name='Mouse',unit=1)}))
        self.assertEqual(mx.firmware_version(dev,255,mx.LONG),'12.34.BABCD')
        self.assertEqual(dev.writes[-1][4], 1)



if __name__ == "__main__":
    unittest.main()
