"""PCG reference-vector and unbiased sampling checks."""

import math
import unittest
from unittest.mock import patch

from analytics.stats.numeric import mean, round_sig
from analytics.stats.rng import PCG32, seed_from


class RNGTests(unittest.TestCase):
    def test_pcg_reference_vector(self):
        rng = PCG32(42, 54)
        self.assertEqual([rng.next_u32() for _ in range(10)], [
            2707161783, 2068313097, 3122475824, 2211639955, 3215226955,
            3421331566, 3217466285, 2167406445, 3860803674, 4181216144,
        ])

    def test_seed_framing_and_pinned_hash(self):
        self.assertEqual(seed_from("exp", "m1"), (17458726204345626802, 7195430894832879134))
        self.assertNotEqual(seed_from("exp", "m1"), seed_from("exp", "m2"))
        self.assertNotEqual(seed_from("a\0b", "c"), seed_from("a", "b\0c"))
        self.assertEqual(PCG32.from_parts("exp", "m1").next_u32(),
                         PCG32(*seed_from("exp", "m1")).next_u32())
        with self.assertRaises(ValueError):
            seed_from(123)

    def test_sampling(self):
        rng = PCG32(42, 54)
        buckets = [0] * 7
        for _ in range(70000):
            buckets[rng.randbelow(7)] += 1
        self.assertTrue(all(abs(n - 10000) < 500 for n in buckets), buckets)
        self.assertLess(sum((n - 10000) ** 2 / 10000 for n in buckets), 22.458)
        self.assertEqual(PCG32(42, 54).uniform(), 0.6303102186438938)
        for n in (1, 2**32, 2**32 + 1, 2**100):
            for _ in range(20):
                self.assertTrue(0 <= rng.randbelow(n) < n)
        for n in (0, -1, 1.2, True):
            with self.assertRaises(ValueError):
                rng.randbelow(n)
        for args in ((-1, 54), (2**64, 54), (0, True)):
            with self.assertRaises(ValueError):
                PCG32(*args)

    def test_randbelow_rejects_biased_draws(self):
        rng = PCG32(42, 54)
        with patch.object(rng, 'next_u32', side_effect=[0, 4]) as draws:
            self.assertEqual(rng.randbelow(7), 4)
            self.assertEqual(draws.call_count, 2)
        # Two 32-bit words per candidate: reject zero, accept n+1.
        n = 2**32 + 1
        with patch.object(rng, 'next_u32', side_effect=[0, 0, 1, 2]) as draws:
            self.assertEqual(rng.randbelow(n), 1)
            self.assertEqual(draws.call_count, 4)

    def test_numeric_helpers(self):
        for value, expected in ((0, 0), (-123.456, -123.5), (1e-300, 1e-300),
                                (5e-324, 5e-324)):
            self.assertEqual(round_sig(value, 4), expected)
        for value in (math.nan, math.inf, -math.inf):
            with self.assertRaises(ValueError):
                round_sig(value)
        self.assertEqual(mean([1e16, 1, -1e16]), 1/3)
        with self.assertRaises(ValueError):
            mean([])
