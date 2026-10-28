"""Regression test: ecore_breathing_rate.py against values captured from native libecore.so.

The expected values come from running Oura's own libecore.so (Android arm64, under qemu) on the
same generated nights: output floats, record count, and a hash of every per-epoch record.
Regenerate with re/make_golden.py (see docs/algorithms/breathing-rate.md).
"""
import hashlib
import math
import random
import unittest

import ecore_breathing_rate as e


def gen_case(seed):
    r = random.Random(seed)
    kind = seed % 6
    n = r.choice([40, 300, 361, 450, 600, 601, 700, 960, 1200, 1900]) if kind else r.choice([200, 500, 800])
    bedtime = r.choice([0, 30000, 1_793_000_000_000 + r.randrange(0, 86_400_000)])
    base = r.choice([280, 350, 450, 600, 800, 1000, 1200, 1500])
    amp = r.choice([0, 5, 20, 50, 100, 200, 300])
    hz = r.choice([0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.7])
    noise = r.choice([0, 2, 10, 30, 80])
    lead = r.choice([0, 0, -45_000, 15_000, 400_000])
    ib, ts = [], []
    t = float(bedtime + lead) if bedtime + lead >= 0 else float(bedtime)
    end = bedtime + n * 30000 + r.choice([0, 60000])
    drift = 0.0
    while t < end:
        drift += r.uniform(-0.5, 0.5) * (kind == 2) * 20
        rr = base + drift + amp * math.sin(2 * math.pi * hz * t / 1000.0) + r.uniform(-noise, noise)
        rr = int(max(220, min(2600 if kind == 3 else 1999, rr)))
        ib.append(rr)
        stamp = int(t)
        if kind == 4 and r.random() < 0.05:
            stamp = bedtime + 30000 * round((stamp - bedtime) / 30000)  # beats exactly on epoch edges
        ts.append(stamp)
        t += rr
        if r.random() < 0.002:
            t += r.choice([1000, 5000, 30000, 95000, 300000])
    if kind == 4:
        ts.sort()
    if kind == 5 and len(ib) > 10:  # a few out-of-order / duplicated stamps
        for _ in range(5):
            i = r.randrange(1, len(ts))
            ts[i] = ts[i - 1]
    motion_kind = r.choice(["zero", "zero", "sparse", "busy", "random"])
    if motion_kind == "zero":
        m = [0] * n
    elif motion_kind == "sparse":
        m = [r.choice([0] * 20 + [1, 3, 8, 30]) for _ in range(n)]
    elif motion_kind == "busy":
        m = [r.choice([0, 2, 4, 10, 30]) for _ in range(n)]
    else:
        m = [r.randrange(0, 256) for _ in range(n)]
    return n, bedtime, ib, ts, m


GOLDEN = [
    # (seed, native output (br, brv, hr), record count, sha256(records)[:16])
    (1, (18.0, 4.75, 75.125), 360, '0694c77155dbf148'),
    (2, (0.0, 0.0, 0.0), 39, '29957b89f7be1566'),
    (3, (19.125, 4.5, 127.5), 449, '6571c9365e849c24'),
    (4, (12.125, 1.5, 50.0), 449, 'dd34aabb688d7b3b'),
    (16, (15.0, 1.875, 75.125), 600, '6996990a3fb544b1'),
    (23, (19.25, 4.625, 75.125), 599, '4b0fcb12dd0710c9'),
]


class NativeGoldenTest(unittest.TestCase):
    def test_matches_native_records_and_output(self):
        for seed, expected, count, digest in GOLDEN:
            with self.subTest(seed=seed):
                n, bedtime, ibi, ts, motion = gen_case(seed)
                out = e.calculate_breathing_rate(bedtime, ibi, ts, motion)
                got = (out.avg_breathing_rate, out.avg_breathing_rate_variability, out.avg_heart_rate)
                self.assertEqual(got, expected)
                records = [(r.time_ms & 0xFFFFFFFFFFFFFFFF, r.heart_rate, r.breathing_rate, r.variability,
                            r.motion, r.status)
                           for r in e.calculate_epoch_records(bedtime, ibi, ts, motion)]
                self.assertEqual(len(records), count)
                self.assertEqual(hashlib.sha256(repr(records).encode()).hexdigest()[:16], digest)


class Fix16Test(unittest.TestCase):
    def test_div(self):
        self.assertEqual(e._fix16_div(0x10000, 0x30000), 0x5555)
        self.assertEqual(e._fix16_div(-0x10000, 0x30000), -0x5555)
        self.assertEqual(e._fix16_div(0xF00000, 16 << 16), 0xF0000)
        self.assertEqual(e._fix16_div(1, 0), -0x80000000)
        self.assertEqual(e._fix16_div(0x7FFF0000, 0x100), -0x80000000)  # overflow

    def test_mul_sqrt_add(self):
        self.assertEqual(e._fix16_mul(0x18000, 0x18000), 0x24000)
        self.assertEqual(e._fix16_mul(-0x18000, 0x18000), -0x24000)
        self.assertEqual(e._fix16_mul(0x7FFF0000, 0x20000), -0x80000000)
        self.assertEqual(e._fix16_sqrt(0x40000), 0x20000)
        self.assertEqual(e._fix16_sqrt(0x20000), 0x16A0A)
        self.assertEqual(e._fix16_add(0x7FFF0000, 0x10000), -0x80000000)
        self.assertEqual(e._fix16_sub(-0x7FFF0000, 0x20000), -0x80000000)


if __name__ == "__main__":
    unittest.main()
