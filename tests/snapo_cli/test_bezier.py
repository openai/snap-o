import json
import unittest
from test_snapo import snapo


class BezierTests(unittest.TestCase):
    def test_parse_normalized_curve(self):
        value = {"x1": 0.2, "y1": 0.1, "x2": 0.8, "y2": 0.9}
        self.assertEqual(value, snapo.parse_tweak_value({"type": "bezier"}, json.dumps(value)))

    def test_invalid_curves(self):
        for value in [{"x1": 2, "y1": 0, "x2": 1, "y2": 1},
                      {"x1": 0, "y1": -0.1, "x2": 1, "y2": 1},
                      {"x1": 0, "y1": 0, "x2": 1, "y2": 1.1},
                      {"x1": 0, "y1": float("nan"), "x2": 1, "y2": 1},
                      {"x1": 0, "y1": 1e99, "x2": 1, "y2": 1},
                      {"x1": 0, "y1": 10**400, "x2": 1, "y2": 1},
                      {"x1": False, "y1": 0, "x2": 1, "y2": 1},
                      {"x1": 0, "y1": 0, "x2": 1}, [0, 0, 1, 1]]:
            with self.subTest(value=value), self.assertRaises(snapo.SnapOError):
                snapo.parse_tweak_value({"type": "bezier"}, json.dumps(value))

    def test_y_bounds(self):
        with self.assertRaises(snapo.SnapOError):
            snapo.parse_tweak_value({"type": "bezier", "yMin": 0.2, "yMax": 0.8},
                                   '{"x1":0.2,"y1":0,"x2":0.8,"y2":1}')
