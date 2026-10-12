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


def fake_entry(index=0):
    dev = FakeDevice()
    info = {"product_string": f"MX Master {index}", "product_id": 0x0001,
            "usage_page": 0xFF00, "usage": 0x0001, "path": f"/dev/fake{index}",
            "in_len": 20, "out_len": 20}
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
                                        r["device_index"], r["feature_index"])
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

    def test_validation_catches_bad_values(self):
        bad = {"channel_a": 1, "channel_b": 1, "device": "all"}
        self.assertIn("channel_a and channel_b must differ",
                      mx.validate_config(bad))
        bad = {"channel_a": 1, "channel_b": 4, "device": "all"}
        self.assertTrue(mx.validate_config(bad))
        bad = {"channel_a": 1, "channel_b": 2, "device": "nope"}
        self.assertTrue(mx.validate_config(bad))


class CliTests(unittest.TestCase):
    def setUp(self):
        self.orig_iter = mx.iter_devices
        self.orig_host = mx.host_info
        self.devices = []

    def tearDown(self):
        mx.iter_devices = self.orig_iter
        mx.host_info = self.orig_host

    def install(self, entries, host=(3, 0)):
        self.devices = entries

        def fake_iter(want_all):
            devs = entries if want_all else entries[:1]
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


if __name__ == "__main__":
    unittest.main()
