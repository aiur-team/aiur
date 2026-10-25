"""Registered secondary FDR thresholds stay distinct from primary alpha."""
import unittest

from analytics.stats import analyze


def inputs():
    rows = [{"unit_id": f"{group}{i}", "group": group, "value": int(i < successes)}
            for group, successes in (("a", 10), ("b", 19)) for i in range(40)]
    return ({"experiment_id": "fdr", "groups": ["a", "b"], "metrics": {"conversion": {"rows": rows}}},
            {"metrics": [{"id": "conversion", "kind": "binary", "direction": "increase", "mde": .01}],
             "primary_metrics": [], "alpha": .05, "fdr_q": .1})


class RegisteredFdrTest(unittest.TestCase):
    def test_secondary_uses_fdr_q_while_primary_uses_alpha(self):
        snapshot, spec = inputs()
        secondary = analyze(snapshot, spec)["metrics"]["conversion"]
        self.assertGreater(secondary["p_adj"], .05)
        self.assertLess(secondary["p_adj"], .1)
        self.assertEqual(secondary["status"], "significant")
        spec["primary_metrics"] = ["conversion"]
        self.assertEqual(analyze(snapshot, spec)["metrics"]["conversion"]["status"], "inconclusive")

    def test_default_fdr_threshold_is_recorded_and_matches_alpha(self):
        snapshot, spec = inputs()
        del spec["fdr_q"]
        result = analyze(snapshot, spec)
        self.assertEqual(result["defaults"]["fdr_q"], .05)
        self.assertEqual(result["metrics"]["conversion"]["status"], "inconclusive")

    def test_invalid_registered_fdr_threshold_is_rejected(self):
        snapshot, spec = inputs()
        for q in (0, 1, -.1, "0.1", True):
            with self.subTest(q=q), self.assertRaises(ValueError):
                analyze(snapshot, {**spec, "fdr_q": q})
