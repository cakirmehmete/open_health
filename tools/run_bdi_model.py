#!/usr/bin/env python3
"""Breathing disturbances with Oura's SleepNet-BDI model (sleepnet_bdi_0_4_0) on our
stored ring data, per summary night.

The model reads one bedtime's beat intervals (the same ecore-corrected IBIs NSSA
uses), stages it internally and flags 30-s epochs with a likely breathing
disturbance. Its outputs (read from the TorchScript):
  outputMetrics = [bdi_status (2 when ODI >= 15, else 0; NaN on poor signal),
                   status (1 ok, 3 model sleep < 180 min, 4 IBI coverage < 70 %),
                   total_sleep_min, odi_all, odi_nrem, odi_rem]
where ODI is the share of sleep epochs flagged, in percent (not events per hour).
`events_per_hour` here is flagged sleep epochs / (total_sleep_min / 60).
Validator: >= 60 beats, >= 1 valid beat; output capped at 15 h.

Usage: python tools/run_bdi_model.py [DB] [TZ] [--json]       (latest bedtime)
       --batch reads [start_ds, end_ds, captured_unix] triples from stdin (the same
       input as run_sleep_model.py --batch) and prints one result or null per window.
The iOS twin is BreathingModel.swift (+ oura_bdi in TorchBridge.mm).
"""
import hashlib
import json
import math
import sqlite3
import sys
from pathlib import Path

from _common import resolve_db, resolve_model
from epoch_time import build_epochs, is_dated, make_unix_s
from ibi_correction import correct_ibis
from nssa_inputs import TAG_BEDTIME, collect_nssa_inputs

REPO = Path(__file__).resolve().parent.parent
MODEL = resolve_model(REPO, "sleepnet_bdi", "0_4_0", oldest="0_4_0", newest="0_4_999")
CACHE_VERSION = "bdi-0.4.0-r1"
MIN_BEATS = 60

JSON = "--json" in sys.argv
BATCH = "--batch" in sys.argv
args = [a for a in sys.argv[1:] if not a.startswith("--")]
DB = resolve_db(args[0] if args else None, REPO)

con = sqlite3.connect(str(DB))
rows = con.execute("SELECT ring_timestamp, tag, COALESCE(decoded_json, '{}'), captured_unix, body FROM events "
                   "WHERE decoded_json IS NOT NULL OR (tag = 65 AND LENGTH(body) >= 14) "
                   "ORDER BY captured_unix, id").fetchall()
_epochs = build_epochs([r[:4] for r in rows])
_unix_s = make_unix_s(_epochs)
decoded = [(ds, tag, json.loads(js), cu, bytes(body) if body is not None else None)
           for ds, tag, js, cu, body in rows if tag in (0x60, 0x72, 0x75)]


def ms(ds, cu=None):
    u = _unix_s(ds, cu)
    return int(round(u * 1000)) if u is not None else int(ds * 100)


def main_bedtime(start_ds, end_ds, captured):
    """The longest ring bedtime (latest 0x76 per start, same boot) inside the window,
    else the window itself — as run_sleep_model.py picks its NSSA bedtimes."""
    latest = {}
    for ds, tag, js, cu, _body in rows:
        if tag != TAG_BEDTIME:
            continue
        v = json.loads(js)
        s, e = v.get("bedtime_start_ds"), v.get("bedtime_end_ds")
        if s is None or e is None or e <= s or abs(ms(s, cu) - ms(s, captured)) > 300000:
            continue
        if s < end_ds and e > start_ds:
            latest[s] = (s, e)
    if not latest:
        return start_ds, end_ds
    return max(latest.values(), key=lambda b: b[1] - b[0])


_model = None
_cache = None
_cache_path = Path(DB).parent / "bdi_cache.json"


def model():
    global _model
    if _model is None:
        import torch
        _model = torch.jit.load(str(MODEL), map_location="cpu").eval()
    return _model


def cache():
    global _cache
    if _cache is None:
        try:
            _cache = json.loads(_cache_path.read_text())
            if _cache.get("version") != CACHE_VERSION:
                raise ValueError
        except (OSError, ValueError):
            _cache = {"version": CACHE_VERSION, "nights": {}}
    return _cache


def num(x):
    return None if x is None or math.isnan(x) else round(float(x), 3)


def analyze(start_ds, end_ds, captured):
    """One window's breathing result dict, or None when the model can't run."""
    if not is_dated(_epochs, start_ds, captured) or not is_dated(_epochs, end_ds, captured):
        return None
    b_start, b_end = main_bedtime(start_ds, end_ds, captured)
    inputs = collect_nssa_inputs(decoded, b_start, b_end, captured, ms, correct_ibis)
    beats = inputs["ibi"]
    if len(beats) < MIN_BEATS or not any(v == 1 for _, _, _, v in beats):
        return None
    key = hashlib.sha256(json.dumps([CACHE_VERSION, MODEL.name, inputs["bedtime"], beats]).encode()).hexdigest()
    if key in cache()["nights"]:
        return cache()["nights"][key]
    import torch
    bed = torch.tensor(list(inputs["bedtime"]), dtype=torch.long)
    vals = torch.tensor([[float(i), float(a), float(v)] for _, i, a, v in beats], dtype=torch.float32)
    ts = torch.tensor([int(t) for t, _, _, _ in beats], dtype=torch.long)
    try:
        _ts, stages, apnea, metrics, _debug = model()(bed, vals, ts)
    except RuntimeError:
        cache()["nights"][key] = None
        return None
    m = [float(x) for x in metrics.flatten().tolist()]
    codes = stages[:, 0]
    flagged = int(((codes >= 1) & (codes <= 3) & (apnea[:, 0] >= 0.5)).sum()) if len(codes) else 0
    sleep_min = m[2] if len(m) > 2 and not math.isnan(m[2]) else None
    out = {
        "start_ds": start_ds, "captured_unix": captured,
        "status": int(m[1]) if not math.isnan(m[1]) else None,
        "elevated": (m[0] == 2) if not math.isnan(m[0]) else None,
        "total_sleep_min": num(sleep_min),
        "odi_pct": num(m[3]), "odi_nrem_pct": num(m[4]), "odi_rem_pct": num(m[5]),
        "flagged_epochs": flagged,
        "events_per_hour": round(flagged / (sleep_min / 60), 2) if sleep_min else None,
        "model": MODEL.stem,
    }
    cache()["nights"][key] = out
    return out


def save_cache():
    try:
        _cache_path.write_text(json.dumps(cache()))
    except OSError:
        pass


if BATCH:
    results = []
    for p in json.load(sys.stdin):
        cu = int(p[2]) if len(p) > 2 else (rows[-1][3] if rows else 0)
        results.append(analyze(int(p[0]), int(p[1]), cu) if MODEL.exists() else None)
    save_cache()
    print(json.dumps(results))
    sys.exit(0)

if not MODEL.exists():
    sys.exit(f"error: model not found: {MODEL} (decrypt notes/models first)")
bt = con.execute("SELECT decoded_json, captured_unix FROM events WHERE tag=118 "
                 "ORDER BY captured_unix DESC, id DESC").fetchone()
if bt is None:
    sys.exit("no bedtime_period (tag 0x76) in DB — sync overnight data first")
v = json.loads(bt[0])
out = analyze(v["bedtime_start_ds"], v["bedtime_end_ds"], bt[1])
save_cache()
if out is None:
    sys.exit("SleepNet-BDI could not run on the latest bedtime (too few beats or undated clock)")
if JSON:
    print(json.dumps(out))
else:
    print(f"status {out['status']}  total sleep {out['total_sleep_min']} min")
    print(f"ODI {out['odi_pct']}% of sleep epochs (NREM {out['odi_nrem_pct']}%, REM {out['odi_rem_pct']}%)"
          f"  -> {out['flagged_epochs']} flagged epochs, {out['events_per_hour']}/h"
          f"{'  ELEVATED' if out['elevated'] else ''}")
