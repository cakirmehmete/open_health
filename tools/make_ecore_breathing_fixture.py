#!/usr/bin/env python3
"""Write apps/ios/OuraApp/Tests/EcoreBreathingFixture.json for EcoreBreathingTests.swift.

The cases are the native-checked nights of test_ecore_breathing_rate.py (same seeds, whose
outputs and record hashes match libecore), plus the per-epoch records this port produces,
so the Swift twin is checked record by record against the same native-verified values.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ecore_breathing_rate as e  # noqa: E402
from test_ecore_breathing_rate import GOLDEN, gen_case  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "apps/ios/OuraApp/Tests/EcoreBreathingFixture.json"


def main():
    cases = []
    for seed, expected, count, _digest in GOLDEN:
        n, bedtime, ibi, ts, motion = gen_case(seed)
        # Trim beats that can never be read, to keep the fixture small: the scan stops at
        # the first stamp past the last epoch, and stamps before the first window never count.
        last = bedtime + (n - 1) * 30000
        stop = next((i for i, t in enumerate(ts) if t > last), len(ts))
        begin = 0
        while begin < stop and ts[begin] < bedtime - 30000:
            begin += 1
        ibi, ts = ibi[begin:stop], ts[begin:stop]
        out = e.calculate_breathing_rate(bedtime, ibi, ts, motion)
        assert (out.avg_breathing_rate, out.avg_breathing_rate_variability, out.avg_heart_rate) == expected
        records = e.calculate_epoch_records(bedtime, ibi, ts, motion)
        assert len(records) == count
        cases.append({
            "seed": seed, "bedtime_ms": bedtime, "ibi": ibi, "ts": ts, "motion": motion,
            "output": list(expected),
            "records": [[r.time_ms, r.heart_rate, r.breathing_rate, r.variability, r.motion, r.status]
                        for r in records],
        })
    motion_events = [(1_000, 3), (30_000, 5), (30_001, 2), (95_000, 40), (-5, 9), (900_000, 1)]
    fixture = {
        "cases": cases,
        "motion_per_epoch": {
            "bedtime_ms": 0, "epochs": 10, "events": motion_events,
            "expected": e._motion_per_epoch(0, 10, motion_events),
        },
        "fix16": {
            "div": [[a, b, e._fix16_div(a, b)] for a, b in
                    [(0x10000, 0x30000), (-0x10000, 0x30000), (0xF00000, 16 << 16), (1, 0), (0x7FFF0000, 0x100),
                     (0x75300000, 0x3E80000), (0xF00000, 0x170000), (123456789, -98765)]],
            "sqrt": [[v, e._fix16_sqrt(v)] for v in [0x40000, 0x20000, 0, 1, 0x7FFFFFFF, 0x123456]],
        },
    }
    OUT.write_text(json.dumps(fixture, separators=(",", ":")))
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes, {len(cases)} cases)")


if __name__ == "__main__":
    main()
