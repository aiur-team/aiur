"""Reference and edge tests for the rank statistics."""

import itertools
import json
import math
from pathlib import Path
import unittest

from analytics.stats.ranks import (
    _u_counts, cliffs_delta, hodges_lehmann, mann_whitney_u, min_achievable_p,
)


class RankTests(unittest.TestCase):
    def test_u_exact_matches_enumeration(self):
        # Independent label enumeration checks the whole DP, not only one tail.
        for n1, n2 in ((1, 5), (2, 4), (3, 5), (4, 4), (5, 6)):
            counts = [0] * (n1 * n2 + 1)
            for positions in itertools.combinations(range(1, n1 + n2 + 1), n1):
                u = sum(positions) - n1 * (n1 + 1) // 2
                counts[u] += 1
            self.assertEqual(tuple(counts), _u_counts(n1, n2))
            for positions in itertools.combinations(range(n1 + n2), n1):
                a = list(positions)
                b = [x for x in range(n1 + n2) if x not in positions]
                result = mann_whitney_u(a, b)
                u = sum(x > y for x in a for y in b)
                expected = min(1, 2 * sum(counts[:min(u, n1 * n2 - u) + 1])
                               / math.comb(n1 + n2, n1))
                self.assertEqual(result["statistic"], u)
                self.assertEqual(result["p_value"], expected)
                self.assertEqual(result["method"], "exact")

    def test_scipy_rank_goldens(self):
        fixtures = json.loads((Path(__file__).parent / "fixtures/stats/goldens.json").read_text())
        for fixture in fixtures["mann_whitney"]:
            with self.subTest(fixture=fixture):
                result = mann_whitney_u(fixture["a"], fixture["b"])
                self.assertEqual(result["statistic"], fixture["statistic"])
                self.assertAlmostEqual(result["p_value"], fixture["p_value"], delta=1e-9)
                self.assertEqual(result["method"], fixture["method"])

    def test_r_moses_goldens(self):
        fixtures = json.loads((Path(__file__).parent / "fixtures/stats/goldens.json").read_text())
        for fixture in fixtures["hodges_lehmann"]:
            with self.subTest(fixture=fixture):
                result = hodges_lehmann(fixture["a"], fixture["b"], fixture.get("confidence", 0.95))
                self.assertAlmostEqual(result["statistic"], fixture["statistic"], delta=1e-9)
                for endpoint in ("lo", "hi"):
                    expected = fixture[endpoint]
                    expected = float(expected) if isinstance(expected, str) else expected
                    self.assertEqual(result[endpoint], expected)
                self.assertEqual(result["method"], fixture["method"])

    def test_separation_and_minimum(self):
        a, b = [1, 2, 3, 4], [5, 6, 7, 8]
        self.assertEqual(mann_whitney_u(a, b)["p_value"], 2 / 70)
        self.assertEqual(min_achievable_p(4, 4), 2 / 70)
        self.assertEqual(min_achievable_p(1, 1), 1)
        self.assertEqual(cliffs_delta(a, b)["statistic"], 1)
        self.assertEqual(cliffs_delta(b, a)["statistic"], -1)
        for sizes in ((0, 4), (4, -1), (True, 4), (4, 1.5)):
            with self.assertRaises(ValueError):
                min_achievable_p(*sizes)

    def test_identical_and_constant_groups(self):
        for values in ([1, 2, 3, 4], [2, 2, 2, 2]):
            self.assertEqual(mann_whitney_u(values, values)["p_value"], 1)
            self.assertEqual(hodges_lehmann(values, values)["statistic"], 0)
            self.assertEqual(cliffs_delta(values, values)["statistic"], 0)

    def test_cliffs_ties_and_bands(self):
        for a, b in (([1, 1, 2, 5], [1, 2, 3, 3]), ([0, 3], [1, 2])):
            expected = sum((y > x) - (y < x) for x in a for y in b) / (len(a) * len(b))
            self.assertEqual(cliffs_delta(a, b)["statistic"], expected)
        for successes, band in ((573, "negligible"), (574, "small"),
                                (665, "medium"), (737, "large")):
            self.assertEqual(cliffs_delta([0], [1] * successes + [-1] * (1000 - successes))
                             ["magnitude"], band)

    def test_interval_unbounded_and_asymptotic(self):
        result = hodges_lehmann([1], [2])
        self.assertEqual((result["lo"], result["hi"]), (-math.inf, math.inf))
        a, b = list(range(51)), list(range(51, 102))
        self.assertEqual(mann_whitney_u(a, b)["method"], "normal_tie_corrected")
        result = hodges_lehmann(a, b)
        self.assertEqual(result["method"], "moses_normal_tie_corrected")
        self.assertLess(result["lo"], result["statistic"])
        self.assertGreater(result["hi"], result["statistic"])
        self.assertEqual((result["lo"], result["hi"]), (45, 57))
        self.assertEqual(mann_whitney_u(range(50), range(50, 100))["method"], "exact")
        tied = hodges_lehmann([1, 1, 2, 5], [1, 2, 3, 3])
        self.assertEqual((tied["statistic"], tied["lo"], tied["hi"]), (0.5, -4, 2))
        for confidence in (0, 1, -1, math.nan, math.inf, True, "0.95", None):
            with self.assertRaises(ValueError):
                hodges_lehmann([1], [2], confidence)

    def test_validation_and_no_mutation(self):
        for function in (mann_whitney_u, hodges_lehmann, cliffs_delta):
            for group in ("a", "b"):
                with self.subTest(function=function.__name__, group=group):
                    args = ([], [1]) if group == "a" else ([1], [])
                    with self.assertRaisesRegex(ValueError, group):
                        function(*args)
            for invalid in (math.nan, math.inf, -math.inf):
                with self.assertRaises(ValueError):
                    function([invalid], [1])
            a, b = [3, 1, 2], [5, 4, 6]
            function(a, b)
            self.assertEqual((a, b), ([3, 1, 2], [5, 4, 6]))


if __name__ == "__main__":
    unittest.main()
