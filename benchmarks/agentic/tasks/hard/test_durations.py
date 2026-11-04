import unittest
from durations import format_duration, parse_duration
from stats import total


class TestFormat(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(format_duration(5415), "1h30m15s")

    def test_single_units(self):
        self.assertEqual(format_duration(1), "1s")
        self.assertEqual(format_duration(60), "1m")
        self.assertEqual(format_duration(86400 + 1), "1d1s")

    def test_zero_and_negative(self):
        self.assertEqual(format_duration(0), "0s")
        with self.assertRaises(ValueError):
            format_duration(-1)


class TestParse(unittest.TestCase):
    def test_roundtrip(self):
        for n in [0, 1, 59, 60, 61, 3599, 3600, 86399, 90061, 10 ** 6]:
            self.assertEqual(parse_duration(format_duration(n)), n)

    def test_spaces_order_case(self):
        self.assertEqual(parse_duration("1h 30m"), 5400)
        self.assertEqual(parse_duration("15S 1H"), 3615)

    def test_invalid(self):
        for bad in ["", "   ", "10", "1h1h", "5x", "h", "1.5h", "-1s"]:
            with self.assertRaises(ValueError, msg=bad):
                parse_duration(bad)


class TestStats(unittest.TestCase):
    def test_total(self):
        self.assertEqual(total(["1m", "", "  ", "30s"]), 90)

    def test_total_propagates_errors(self):
        with self.assertRaises(ValueError):
            total(["1m", "oops"])

    def test_total_empty(self):
        self.assertEqual(total([]), 0)


if __name__ == "__main__":
    unittest.main()
