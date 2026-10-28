# Breathing rate (ecore) — exact port

`tools/ecore_breathing_rate.py` is a bit-exact Python port of Oura's nightly breathing-rate
calculation, `nexus::ecore::ecore_cpp_calculate_breathing_rate` →
`breathing_rate_calculate_averages`, from `libecore.so` (arm64) in the Oura Android app
7.28.1 (`@ 0x200e6c` in that build). Breathing rate is native ecore code, not a TorchScript
model. Symptom Radar reads it as its `averageBreath` input.

```sh
python3 tools/ecore_breathing_rate.py [oura.db] [--json] [--no-motion]
python3 tools/ecore_breathing_rate.py --self-test
python3 -m unittest tools/test_ecore_breathing_rate.py
```

Python API: `calculate_breathing_rate(bedtime_start_ms, ibi_ms, ibi_timestamps_ms,
motion_seconds_per_epoch)` returns `(avg_breathing_rate, avg_breathing_rate_variability,
avg_heart_rate)`, each a float32 in 1/8 steps. `calculate_epoch_records(...)` returns the
per-epoch records that the native code keeps.

## Inputs

| Argument | Meaning |
|---|---|
| `bedtime_start_ms` | Start of the bedtime period, same clock as the beat timestamps |
| `ibi_ms[]`, `ibi_timestamps_ms[]` | Beat-to-beat intervals and their times. Intervals ≥ 2000 ms are ignored |
| `motion_seconds[]` | One value per 30 s epoch. **Its length is the epoch count.** |

The CLI reads the newest 0x76 bedtime, the corrected IBIs (as the NSSA runner does) and
0x47 `motion_seconds`. It places each motion event in the epoch window `(t − 30 s, t]`. That
alignment is an assumption: how the app builds the motion array is not confirmed. Use
`--no-motion` to treat every epoch as still.

## Algorithm

Epoch *k* covers the 30 s ending at `t = bedtime + 30 s·k`. Beats with
`t − 30 000 ≤ ts ≤ t` count, so a beat that falls exactly on a boundary counts in both
epochs. The scan stops at the first timestamp after `t`. The comparison is unsigned 64-bit,
so within 30 s of time zero no beat counts.

State is kept for the last **4 epochs** ("slots"). Each slot has a range in a 256-entry IBI
ring and a range in a 64-entry breathing-peak ring. Epoch 0 only fills the ring; each later
epoch writes one 14-byte record (up to 1800):

1. **Heart rate.** Mean IBI over the 4 slots in Q10 (`(Σ·1024 + n/2)/n`, or `0xB0800` if
   empty). Then `fix16_div(30.0·2¹⁶·…)`: beats per 30 s, ×2, floor at 35 bpm, ×2 again,
   rounded. The record stores half-bpm (0..255).
2. **Resample + filter.** This epoch's new IBIs go into a streaming 4 Hz resampler (linear
   interpolation in Q15, 250 ms grid). Each sample is filtered by a 12-pole IIR computed in
   float-float (double-single) arithmetic, and the result is rounded to Q16.
3. **Peak detection.** A falling edge after a rise is a peak. Its interval (samples since the
   last stored peak, capped at 255) and a sign byte (≈ filtered value / 2, saturated) go into
   the current slot's peak range.
4. **Breathing rate.** If this epoch produced fewer than 41 samples, the record gets the
   defaults BR = 0x6A and BRV = 0x2A. Otherwise the code walks the peaks of the 4 slots in
   order. It accepts interval *i* when the running sum of previous intervals is > 40 and both
   this peak and the previous one are positive, with interval > 8. Then
   `rate×256 = ((Σ & ~1) + n·0xF000) / Σ` and `BR = (rate×256 + 16) >> 5` (1/8 br/min).
5. **Variability.** Everything is libfixmath Q16: `mean = rate×256 / 256`, and for each
   accepted interval `d = 240/interval − mean`, accumulated as `Σ d²` with saturating add.
   Then `sqrt(Σ/n)` (only when n > 1 and Σ > 0), ×8, rounded, clamped to 0..255.
6. **Status.**
   - **2:** the current epoch added ≤ 1 beat. The values are replaced by fixed bytes and the
     record never counts.
   - **0:** too much motion. In the first 10 epochs, that means the motion sum of epochs
     *w−2..w−5* is ≥ 7. Later, it means more than 3 of the last 12 four-epoch windows had
     motion > 2 *and* one of the last 4 BRV values was > 27 (3.4 br/min).
   - **1:** valid.

   Status 0 and 1 records also push their BRV into that 4-entry history.

The night average uses records `[n/2 − 180, n/2 + 180)` when 361 ≤ n ≤ 600, and
`[120, n − 120)` when n > 600, capped at 1800. Nights of n ≤ 360 epochs return 0. The
average skips status-2 records and rounds to nearest:
`BR = (ΣBR + c/2)/c / 8`, `BRV` likewise, `HR = (ΣHR·4 + c/2)/c / 8`. **Status-0 records
still count;** only status 2 is excluded.

## Verification

Run on the Services VM in `/home/emre/opencode-work/oura-session/re/` (needs the arm64
`libecore.so` loaded through the glibc shim under `qemu-aarch64-static`, as set up in the
reverse-engineering session):

- `compare.py`: random nights (40–1900 epochs; bedtime 0, 30 000 or a real 2026 epoch; HR
  40–270 bpm; breathing 0.1–0.7 Hz; noise; gaps up to 5 min; intervals ≥ 2000 ms; beats on
  epoch edges; out-of-order/duplicate stamps; random motion). It compares the output floats
  **and every per-epoch record** (time, HR, BR, BRV, motion, status) with native.
- `compare_files.py`: the 30 earlier hand-made cases, plus a night exported from a synthetic
  `oura.db` through the CLI's own loader (`export_db_night.py`).
- `compare_iir.py`: 200 000 IIR samples, including jumps between 1 and 32767.

Result on 2026-10-28: every case was bit-identical (see `re/RESULTS.md`). The unit test
repeats 6 of these nights against stored native outputs and record hashes, so it runs
anywhere without the Android library.

Not covered: real ring data (none available yet), and how the app builds the motion array
(see above).
