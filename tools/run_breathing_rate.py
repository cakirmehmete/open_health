#!/usr/bin/env python3
"""Nightly breathing rate with Oura's own ecore algorithm (tools/ecore_breathing_rate.py,
a bit-exact port of libecore's breathing_rate_calculate_averages), per summary night.

Inputs per night are what the Oura app feeds it: the night's longest ring bedtime (as
run_bdi_model.py picks it), its ecore-corrected beat intervals (the same IBIs NSSA reads)
and 0x47 motion seconds per 30 s epoch. Nights of 360 epochs (3 h) or fewer get no value.

Usage: python tools/run_breathing_rate.py [DB] [TZ] --batch
       reads [start_ds, end_ds, captured_unix] triples from stdin (the same input as
       run_sleep_model.py --batch) and prints one result or null per window.
The iOS twin is NightBreathing.swift (on EcoreBreathing.swift).
"""
import json
import sqlite3
import sys
from pathlib import Path

from _common import resolve_db
from ecore_breathing_rate import _motion_per_epoch, calculate_breathing_rate
from epoch_time import build_epochs, is_dated, make_unix_s
from ibi_correction import correct_ibis
from nssa_inputs import TAG_BEDTIME, collect_nssa_inputs

REPO = Path(__file__).resolve().parent.parent
TAG_MOTION = 0x47
EPOCH_MS = 30_000


def load(db_path):
    con = sqlite3.connect(str(db_path))
    try:
        rows = con.execute("SELECT ring_timestamp, tag, COALESCE(decoded_json, '{}'), captured_unix, body FROM events "
                           "WHERE decoded_json IS NOT NULL OR (tag = 65 AND LENGTH(body) >= 14) "
                           "ORDER BY captured_unix, id").fetchall()
    finally:
        con.close()
    return rows


class Nights:
    def __init__(self, rows):
        self.rows = rows
        self.epochs = build_epochs([r[:4] for r in rows])
        self._unix_s = make_unix_s(self.epochs)
        self.decoded = [(ds, tag, json.loads(js), cu, bytes(body) if body is not None else None)
                        for ds, tag, js, cu, body in rows if tag in (0x60, 0x72, 0x75)]
        self.bedtimes = []
        self.motion = []
        for ds, tag, js, cu, _body in rows:
            if tag == TAG_BEDTIME:
                v = json.loads(js)
                s, e = v.get("bedtime_start_ds"), v.get("bedtime_end_ds")
                if s is not None and e is not None and e > s:
                    self.bedtimes.append((s, e, cu))
            elif tag == TAG_MOTION:
                self.motion.append((ds, cu, int(json.loads(js).get("motion_seconds", 0) or 0)))

    def ms(self, ds, cu=None):
        u = self._unix_s(ds, cu)
        return int(round(u * 1000)) if u is not None else int(ds * 100)

    def main_bedtime(self, start_ds, end_ds, captured):
        """run_bdi_model.main_bedtime: the longest ring bedtime in the window, same boot."""
        latest = {}
        for s, e, cu in self.bedtimes:
            if abs(self.ms(s, cu) - self.ms(s, captured)) > 300000:
                continue
            if s < end_ds and e > start_ds:
                latest[s] = (s, e)
        if not latest:
            return start_ds, end_ds
        return max(latest.values(), key=lambda b: b[1] - b[0])

    def analyze(self, start_ds, end_ds, captured):
        if not is_dated(self.epochs, start_ds, captured) or not is_dated(self.epochs, end_ds, captured):
            return None
        b_start, b_end = self.main_bedtime(start_ds, end_ds, captured)
        inputs = collect_nssa_inputs(self.decoded, b_start, b_end, captured, self.ms, correct_ibis)
        start_ms, end_ms = inputs["bedtime"]
        epochs = max(0, (end_ms - start_ms) // EPOCH_MS)
        beats = inputs["ibi"]
        if epochs <= 360 or not beats:
            return None
        events = sorted((self.ms(ds, cu), sec) for ds, cu, sec in self.motion if b_start <= ds <= b_end)
        motion = _motion_per_epoch(start_ms, epochs, events)
        out = calculate_breathing_rate(start_ms, [b[1] for b in beats], [b[0] for b in beats], motion)
        if out.avg_breathing_rate <= 0:
            return None
        return {
            "start_ds": start_ds, "captured_unix": captured,
            "breath_rate": out.avg_breathing_rate,
            "breath_rate_variability": out.avg_breathing_rate_variability,
            "heart_rate": out.avg_heart_rate,
            "epochs": epochs, "beats": len(beats),
            "source": "ecore",
        }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    db = resolve_db(args[0] if args else None, REPO)
    nights = Nights(load(db))
    if "--batch" in sys.argv:
        results = []
        for p in json.load(sys.stdin):
            cu = int(p[2]) if len(p) > 2 else (nights.rows[-1][3] if nights.rows else 0)
            results.append(nights.analyze(int(p[0]), int(p[1]), cu))
        print(json.dumps(results))
        return 0
    if not nights.bedtimes:
        sys.exit("no bedtime_period (tag 0x76) in DB — sync overnight data first")
    s, e, cu = nights.bedtimes[-1]
    print(json.dumps(nights.analyze(s, e, cu)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
