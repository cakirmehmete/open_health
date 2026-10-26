#!/usr/bin/env python3
"""Compute Oura's *daytime stress* timeseries locally and run the decrypted
`stress_daytime_sensing_1_1_0` model on our stored ring data — no cloud.

The model is a small deterministic transform (recovered from its TorchScript):

    intensity            = dhrv_value - dhrv_baseline          # HRV vs daytime baseline
    neutral_zone_half    = f(night_hrv_baseline)               # 2 / 3 / 4 ms dead-zone
    stress_threshold     = -neutral_zone_half                  # below -> "stressed"
    recovery_threshold   = +neutral_zone_half                  # above -> "restored"
    stress_saturation    = lut(night_hrv_baseline)             # negative clamp
    recovery_saturation  = lut(night_hrv_baseline)             # positive clamp
    scaled_*             = scale_output(intensity, thresholds, saturations)

The 8 outputs map 1:1 onto `TimeseriesDbDaytimeStress` (intensity / intensity_scaled
/ stress_limit{,_scaled} / recovery_limit{,_scaled} / saturation_stress_deviation /
saturation_recovery_deviation), i.e. running this per sample reconstructs the exact
daytime-stress timeseries Oura would have synced.

INPUT GATE (enforced by the model's own `validator`): each sample needs a single
*awake, sedentary* daytime HRV reading —
  * timestamp must fall OUTSIDE every bedtime window (else code 6 "Sleep detected"),
  * ring_met <= 1.8 (else code 3 "exceeded limit for activity"),
  * dhrv / both baselines must be one positive observation.
Our captures are mostly nocturnal, so few samples qualify; enable the `daytime_hr`
feature (`oura feature daytime_hr ...`) to collect awake HRV and this fills in.

Inputs, all on the dated wall clock (epoch_time), timestamps and bedtimes in unix ms:
  * dhrv: the ring's own RMSSD averages (`hrv_event`, 0x5d). A packet is stamped at
    its LAST average; earlier ones walk back by `interval_min` (as nssa_inputs does).
  * bedtimes: the ring's `bedtime_period` (0x76) windows.
  * ring_met: the mean per-minute MET (0x50) over the sample's interval; `--met` only
    when no MET covers it (counted as `met_imputed`).
  * baselines, per local day over the trailing BASELINE_DAYS: night_hrv_baseline is
    the median nocturnal RMSSD; dhrv_baseline the median awake RMSSD (the night
    baseline when fewer than MIN_DAYTIME_FOR_BASELINE awake samples — the app uses
    `dhrv_imputation` here; we approximate).

Usage: python tools/run_stress_model.py [DB] [TZ] [--met M] [--json]
`--json` prints {model, days: [{date, stressed_min, restored_min, neutral_min, ...}],
samples: [{unix, dhrv, met, intensity, intensity_scaled, zone, ...}], rejected}.
The iOS twin is StressModel.swift (+ oura_stress in TorchBridge.mm).
"""
import argparse
import datetime
import json
import sqlite3
import sys
from pathlib import Path
from statistics import median

from _common import resolve_db, resolve_model
from epoch_time import build_epochs, is_dated, make_unix_s

REPO = Path(__file__).resolve().parent.parent
MODEL = resolve_model(REPO, "stress_daytime_sensing", "1_1_0", newest="1_999_0")
BASELINE_DAYS = 14
MIN_DAYTIME_FOR_BASELINE = 3  # below this, dhrv_baseline falls back to the night baseline
MAX_DAYS = 14                 # days of samples reported
OUT_LABELS = ["intensity", "stress_limit", "recovery_limit",
              "saturation_stress_deviation", "saturation_recovery_deviation",
              "intensity_scaled", "stress_limit_scaled", "recovery_limit_scaled"]


def load(db):
    """(bedtimes [(start_ms, end_ms)], hrv [(unix_s, rmssd, interval_s)], met {minute: met})."""
    con = sqlite3.connect(str(db))
    rows = con.execute("SELECT ring_timestamp, tag, decoded_json, captured_unix FROM events "
                       "WHERE decoded_json IS NOT NULL ORDER BY captured_unix, id").fetchall()
    con.close()
    epochs = build_epochs(rows)
    unix_s = make_unix_s(epochs)
    bedtimes, hrv, met = set(), [], {}
    for ds, tag, js, cu in rows:
        if tag not in (0x5D, 0x76, 0x50):
            continue
        try:
            v = json.loads(js)
        except ValueError:
            continue
        if tag == 0x76:
            s, e = v.get("bedtime_start_ds"), v.get("bedtime_end_ds")
            if s is None or e is None or e <= s or not is_dated(epochs, s, cu) or not is_dated(epochs, e, cu):
                continue
            bedtimes.add((int(round(unix_s(s, cu) * 1000)), int(round(unix_s(e, cu) * 1000))))
            continue
        if not is_dated(epochs, ds, cu):
            continue
        base = unix_s(ds, cu)
        if tag == 0x50 and isinstance(v.get("met"), list):
            minute = round(base / 60)
            for i, m in enumerate(v["met"]):
                met[minute + i] = float(m)
        elif tag == 0x5D:
            step = float(v.get("interval_min", 5)) * 60.0
            rm = v.get("rmssd_ms") or []
            n = len(rm)
            for i, r in enumerate(rm):
                if r and r > 0:
                    hrv.append((base - (n - 1 - i) * step, float(r), step))
    # One entry per sample time (re-synced packets repeat).
    hrv = sorted({round(t): (t, r, st) for t, r, st in hrv}.values())
    return sorted(bedtimes), hrv, met


def asleep(t_ms, bedtimes):
    return any(s <= t_ms <= e for s, e in bedtimes)


def sample_met(t, step, met):
    """Mean ring MET over the interval ending at `t`, or None without coverage."""
    hi = round(t / 60)
    vals = [met[m] for m in range(hi - max(1, round(step / 60)) + 1, hi + 1) if m in met]
    return sum(vals) / len(vals) if vals else None


def run(model, dhrv, t_ms, bedtimes, dhrv_baseline, night_baseline, ring_met):
    """Call the model for one sample; return (ok, result_or_errcode)."""
    import torch
    bs = torch.tensor([float(s) for s, _ in bedtimes], dtype=torch.float64)
    be = torch.tensor([float(e) for _, e in bedtimes], dtype=torch.float64)
    try:
        out = model(
            torch.tensor([dhrv], dtype=torch.float32),
            torch.tensor([float(t_ms)], dtype=torch.float64),
            bs, be,
            torch.tensor([dhrv_baseline], dtype=torch.float32),
            torch.tensor([night_baseline], dtype=torch.float32),
            torch.tensor([ring_met], dtype=torch.float32),
        )
        return True, {l: float(o.flatten()[0]) for l, o in zip(OUT_LABELS, out)}
    except Exception as e:  # validator raised "<code>, <message>"
        msg = str(e).strip().splitlines()[-1]
        return False, msg


def zone(intensity, stress_lim, recovery_lim):
    if intensity <= stress_lim:
        return "stressed"
    if intensity >= recovery_lim:
        return "restored"
    return "neutral"


def analyze(db, tz_hours, default_met):
    import torch
    bedtimes, hrv, met = load(db)
    if not bedtimes or not hrv:
        return None
    model = torch.jit.load(str(MODEL), map_location="cpu").eval()

    def day_of(t):
        return datetime.datetime.utcfromtimestamp(t + tz_hours * 3600).date()

    night = [(day_of(t), r) for t, r, _ in hrv if asleep(t * 1000, bedtimes)]
    awake = [(t, r, st) for t, r, st in hrv if not asleep(t * 1000, bedtimes)]
    if not night or not awake:
        return None
    newest = day_of(awake[-1][0])
    first = newest - datetime.timedelta(days=MAX_DAYS - 1)

    def baselines(day):
        lo = day - datetime.timedelta(days=BASELINE_DAYS - 1)
        n = [r for d, r in night if lo <= d <= day]
        a = [r for t, r, _ in awake if lo <= day_of(t) <= day]
        if not n:
            return None
        nb = median(n)
        return nb, (median(a) if len(a) >= MIN_DAYTIME_FOR_BASELINE else nb), len(a) >= MIN_DAYTIME_FOR_BASELINE

    samples, rejected, days, imputed = [], {}, {}, 0
    for t, dhrv, step in awake:
        day = day_of(t)
        if day < first:
            continue
        b = baselines(day)
        if b is None:
            rejected["no night HRV baseline"] = rejected.get("no night HRV baseline", 0) + 1
            continue
        nb, db_, from_awake = b
        m = sample_met(t, step, met)
        if m is None:
            m, imputed = default_met, imputed + 1
        ok, res = run(model, dhrv, round(t * 1000), bedtimes, db_, nb, m)
        if not ok:
            rejected[res] = rejected.get(res, 0) + 1
            continue
        z = zone(res["intensity"], res["stress_limit"], res["recovery_limit"])
        samples.append({"unix": round(t), "minutes": round(step / 60), "dhrv": dhrv, "met": round(m, 2),
                        "zone": z, **{k: round(v, 3) for k, v in res.items()}})
        d = days.setdefault(day.isoformat(), {
            "date": day.isoformat(), "stressed_min": 0, "restored_min": 0, "neutral_min": 0,
            "samples": 0, "night_hrv_baseline": round(nb, 1), "dhrv_baseline": round(db_, 1),
            "baseline_source": "awake median" if from_awake else "night fallback", "_scaled": []})
        d[f"{z}_min"] += round(step / 60)
        d["samples"] += 1
        d["_scaled"].append(res["intensity_scaled"])
    for d in days.values():
        sc = d.pop("_scaled")
        d["mean_intensity_scaled"] = round(sum(sc) / len(sc), 3)
    return {
        "model": MODEL.stem,
        "awake_hrv_samples": len(awake), "night_hrv_samples": len(night),
        "met_imputed": imputed,
        "neutral_zone_ms": samples[-1]["recovery_limit"] if samples else None,
        "days": sorted(days.values(), key=lambda d: d["date"]),
        "samples": samples,
        "rejected": rejected,
    }


def main():
    ap = argparse.ArgumentParser(description="Local daytime-stress timeseries from ring HRV")
    ap.add_argument("db", nargs="?", help="events DB (default: ./oura.db)")
    ap.add_argument("tz_pos", nargs="?", type=float, help="hours offset (positional, like the other runners)")
    ap.add_argument("--tz", type=float, default=None, help="hours offset for local days")
    ap.add_argument("--met", type=float, default=1.0,
                    help="ring MET for awake samples with no MET coverage (<=1.8; default sedentary 1.0)")
    ap.add_argument("--json", action="store_true", help="emit days + samples as JSON")
    args = ap.parse_args()
    tz = args.tz if args.tz is not None else (args.tz_pos if args.tz_pos is not None else 0.0)

    if not MODEL.exists():
        if args.json:
            print("null")
            return
        sys.exit(f"error: model not found: {MODEL} (decrypt notes/models first)")
    out = analyze(resolve_db(args.db, REPO), tz, args.met)
    if args.json:
        print(json.dumps(out))
        return
    if out is None:
        sys.exit("no awake HRV with a night baseline — enable daytime_hr and sync a day")
    print(f"Daytime stress (local, {out['model']}) — {out['awake_hrv_samples']} awake / "
          f"{out['night_hrv_samples']} nocturnal HRV samples, MET imputed for {out['met_imputed']}")
    for d in out["days"]:
        print(f"  {d['date']}  stressed {d['stressed_min']:3d} min  neutral {d['neutral_min']:3d}  "
              f"restored {d['restored_min']:3d}  (night {d['night_hrv_baseline']} ms, "
              f"awake {d['dhrv_baseline']} ms, {d['baseline_source']})")
    for s in out["samples"]:
        when = datetime.datetime.utcfromtimestamp(s["unix"] + tz * 3600).strftime("%m-%d %H:%M")
        print(f"    {when}  dhrv={s['dhrv']:5.0f}  met={s['met']:.1f}  intensity={s['intensity']:+5.0f}"
              f"  scaled={s['intensity_scaled']:+.2f}  [{s['zone']}]")
    if out["rejected"]:
        print("  rejected samples:")
        for msg, n in sorted(out["rejected"].items(), key=lambda x: -x[1]):
            print(f"    {n:4d} x  {msg}")


if __name__ == "__main__":
    main()
