"""Independent hand-calculated stratified references and composition examples."""

import math
import unittest

from analytics.stats.strata import composition, pooled, standardized


def rows(values, censored=()):
    return [{"value": value, "censored": i in censored} for i, value in enumerate(values)]


def cell(a, b):
    return {"a": rows(a), "b": rows(b)}


class StrataTest(unittest.TestCase):
    def test_van_elteren_untied_hand_reference(self):
        # Midrank U centered scores: -2, -9/2; variances 5/3, 21/4.
        # Weights 1/5, 1/7 give X²=219/35; two-sided normal tail below.
        data = {"one": cell([1, 2], [3, 4]), "two": cell([1, 2, 3], [4, 5, 6])}
        result = pooled(data, ["a", "b"], "continuous")
        self.assertAlmostEqual(result["statistic"], 219 / 35)
        self.assertAlmostEqual(result["p_value"], .01236935338337927)
        self.assertEqual(result["method"], "van_elteren")

    def test_van_elteren_ties_hand_reference(self):
        # U centered scores -4,-3/2, tie-corrected variances 24/5,3/2.
        # Weighted score=-61/70; variance=387/2450 => X²=3721/774.
        data = {"one": cell([1, 1, 2], [2, 3, 3]), "two": cell([1, 2], [2, 4])}
        result = pooled(data, ["a", "b"], "continuous")
        self.assertAlmostEqual(result["statistic"], 3721 / 774)
        self.assertAlmostEqual(result["p_value"], math.erfc(math.sqrt(3721 / 1548)))

    def test_cmh_hypergeometric_hand_reference(self):
        # Tables (success/failure per a,b): [[3,1],[1,3]], [[4,2],[2,4]].
        # Expected a successes 2,3 => summed deviation 2; variances 4/7,9/11.
        # Mantel-Haenszel without correction: X²=4/(4/7+9/11)=308/107.
        data = {"one": cell([1, 1, 1, 0], [1, 0, 0, 0]),
                "two": cell([1, 1, 1, 1, 0, 0], [1, 1, 0, 0, 0, 0])}
        result = pooled(data, ["a", "b"], "binary")
        self.assertAlmostEqual(result["statistic"], 308 / 107)
        self.assertAlmostEqual(result["p_value"], .08976934857474607)
        self.assertEqual(result["method"], "cmh")

    def test_logrank_counts_censored_rows_at_tied_event_time(self):
        # At t=1 all four at risk, one a event => O-E=1/2,V=1/4.
        # The a censor at t=2 leaves a lone b event at t=3: no information.
        data = {"one": {"a": rows([1, 2], censored=(1,)),
                        "b": rows([1, 3], censored=(0,))}}
        result = pooled(data, ["a", "b"], "duration")
        self.assertEqual(result["statistic"], 1)
        self.assertAlmostEqual(result["p_value"], .31731050786291415)
        self.assertEqual(result["method"], "stratified_logrank")
        data["two"] = data["one"]
        self.assertEqual(pooled(data, ["a", "b"], "duration")["statistic"], 2)

    def test_degenerate_scores_are_non_significant(self):
        for kind, values in (("continuous", [3, 3]), ("binary", [0, 0])):
            result = pooled({"one": cell(values, values)}, ["a", "b"], kind)
            self.assertEqual(result["statistic"], 0)
            self.assertEqual(result["p_value"], 1)
        self.assertEqual(pooled({}, ["a", "b"], "continuous")["p_value"], 1)

    def test_composition_fisher_and_chi_square_hand_references(self):
        fisher = composition({"one": cell([1] * 8, [1] * 2),
                              "two": cell([1] * 2, [1] * 8)}, ["a", "b"])
        # 2x2 hypergeometric probability ordering: 2*(C(10,8)^2+100+1)/C(20,10).
        self.assertAlmostEqual(fisher["p_value"], 2 * (2025 + 100 + 1) / 184756)
        self.assertAlmostEqual(fisher["tvd"], .6)
        self.assertEqual(fisher["method"], "fisher_exact")
        chi = composition({"one": cell([1] * 20, [1] * 5),
                           "two": cell([1] * 5, [1] * 20),
                           "three": cell([1] * 5, [1] * 5)}, ["a", "b"])
        # Expected counts 12.5,12.5 and 5,5; X²=18, df=2 => tail exp(-9).
        self.assertAlmostEqual(chi["p_value"], math.exp(-9))
        self.assertAlmostEqual(chi["tvd"], .5)
        self.assertEqual(chi["method"], "chi_square")

    def test_composition_unavailable_is_explicit(self):
        self.assertEqual(composition({}, ["a", "b"]),
                         {"p_value": None, "tvd": None, "method": "unavailable"})
        self.assertIsNone(composition({"one": cell([1], [])}, ["a", "b"])["p_value"])
        self.assertEqual(composition({"one": cell([1], [1, 1])}, ["a", "b"])["tvd"], 0)

    def test_standardization_uses_pooled_mix_and_preserves_strata_bootstrap(self):
        # Raw medians are 1 versus 9; pooled mix is exactly half in each
        # stratum, so each standardized median is (1+9)/2=5 on every draw.
        data = {"one": cell([1] * 8, [1] * 2), "two": cell([9] * 2, [9] * 8)}
        result = standardized(data, ["a", "b"], seed=(42, 54), resamples=50)
        for name, null in (("median_difference", 0), ("median_ratio", 1)):
            self.assertEqual(result[name], {"estimate": null, "lo": null, "hi": null,
                                           "null": null, "method": "percentile_stratified",
                                           "resamples": 50, "mc_se": 0})

        # A different within-stratum treatment effect makes the pooled weight
        # observable: baseline weights (.8,.2) would give difference 1, not 5.
        shifted = {"one": cell([1] * 8, [2] * 2), "two": cell([9] * 2, [18] * 8)}
        effect = standardized(shifted, ["a", "b"], resamples=50)["median_difference"]
        self.assertEqual((effect["estimate"], effect["lo"], effect["hi"]), (5, 5, 5))

    def test_standardized_direction_and_non_degenerate_bootstrap(self):
        data = {"one": cell([1, 2, 3, 4], [4, 5, 6, 7]),
                "two": cell([9, 10], [12, 13])}
        result = standardized(data, ["a", "b"], seed=(23, 54), resamples=200)
        # Dominant stratum has weight 2/3; weighted medians are 3.5,6.5.
        self.assertEqual(result["median_difference"]["estimate"], 3)
        self.assertAlmostEqual(result["median_ratio"]["estimate"], 6.5 / 3.5)
        self.assertGreater(result["median_difference"]["hi"], result["median_difference"]["lo"])
        self.assertGreater(result["median_difference"]["mc_se"], 0)
        self.assertEqual(result, standardized(data, ["a", "b"], seed=(23, 54), resamples=200))

    def test_binary_standardization_uses_proportions_instead_of_medians(self):
        data = {"one": cell([0, 0, 0, 1], [0, 1]),
                "two": cell([1, 1], [0, 1, 1, 1])}
        result = standardized(data, ["a", "b"], seed=(23, 54), resamples=100, kind="binary")
        # Half weight per stratum: a=(.25+1)/2=.625, b=(.5+.75)/2=.625.
        self.assertEqual(list(result), ["proportion_difference"])
        self.assertEqual(result["proportion_difference"]["estimate"], 0)
        self.assertLess(result["proportion_difference"]["lo"], 0)
        self.assertGreater(result["proportion_difference"]["hi"], 0)

    def test_standardized_zero_baseline_omits_ratio(self):
        result = standardized({"one": cell([0, 1], [1, 2])}, ["a", "b"], resamples=10)
        self.assertEqual(result["median_difference"]["estimate"], 1)
        self.assertNotIn("median_ratio", result)

    def test_standardized_rejects_censoring_and_invalid_draws(self):
        data = {"one": {"a": rows([1, 2], censored=(0,)), "b": rows([2, 3])}}
        with self.assertRaisesRegex(ValueError, "uncensored"):
            standardized(data, ["a", "b"], resamples=10)
        for count in (True, 1, 1.5):
            with self.subTest(count=count), self.assertRaises(ValueError):
                standardized({}, ["a", "b"], resamples=count)
        self.assertEqual(standardized({}, ["a", "b"], resamples=2), {})
        with self.assertRaisesRegex(ValueError, "both groups"):
            standardized({"one": cell([1, 2], [])}, ["a", "b"], resamples=2)
