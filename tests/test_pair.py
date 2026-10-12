import ast
from pathlib import Path
import unittest

class PairTests(unittest.TestCase):
    def test_mouse_first_and_missing_keyboard_reported(self):
        for present in (True, False):
            events = []
            class Device:
                def __init__(self, name): self.name = name
                def close(self): events.append(('close', self.name))
            mouse, keyboard = Device('mouse'), Device('keyboard')
            def find(kind=None, product_id=None):
                if kind == 'mouse': return mouse, 255, 17, 10, {'path': 'mouse'}
                self.assertIn(('send', 'mouse'), events)
                return (keyboard, 255, 17, 10, {'path': 'keyboard'}) if present else None
            tree = ast.parse((Path(__file__).resolve().parents[1] / 'python/mxswitch.py').read_text())
            function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'switch_pair')
            import sys
            ns = dict(sys=sys, find_device=find, host_info=lambda *a: (3,0),
                      set_host=lambda device,*a: events.append(('send',device.name)), print=lambda *a,**kw:None)
            exec(compile(ast.Module(body=[function],type_ignores=[]),'pair','exec'),ns)
            self.assertEqual(ns['switch_pair'](2), 0 if present else 1)
            self.assertIn(('close','mouse'),events)
            if present:
                self.assertIn(('send','keyboard'),events)
                self.assertIn(('close','keyboard'),events)

if __name__ == '__main__': unittest.main()
