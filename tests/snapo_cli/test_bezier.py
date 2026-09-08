import json
import unittest
from test_snapo import snapo


class BezierTests(unittest.TestCase):
    def test_parse_overshoot_curve(self):
        value = {"x1": 0.2, "y1": -0.5, "x2": 0.8, "y2": 1.5}
        self.assertEqual(value, snapo.parse_tweak_value({"type": "bezier"}, json.dumps(value)))

    def test_invalid_curves(self):
        for value in [{"x1": 2, "y1": 0, "x2": 1, "y2": 1},
                      {"x1": 0, "y1": -float("inf"), "x2": 1, "y2": 1},
                      {"x1": 0, "y1": 0, "x2": 1, "y2": float("inf")},
                      {"x1": 0, "y1": float("nan"), "x2": 1, "y2": 1},
                      {"x1": 0, "y1": 1e99, "x2": 1, "y2": 1},
                      {"x1": 0, "y1": 10**400, "x2": 1, "y2": 1},
                      {"x1": False, "y1": 0, "x2": 1, "y2": 1},
                      {"x1": 0, "y1": 0, "x2": 1}, [0, 0, 1, 1]]:
            with self.subTest(value=value), self.assertRaises(snapo.SnapOError):
                snapo.parse_tweak_value({"type": "bezier"}, json.dumps(value))

    def test_finite_float_extremes(self):
        value = {"x1": 0, "y1": -3.4028234663852886e38, "x2": 1, "y2": 3.4028234663852886e38}
        self.assertEqual(value, snapo.parse_tweak_value({"type": "bezier"}, json.dumps(value)))
