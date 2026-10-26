# Running Oura's on-device models on your synced data

The ring ships Oura's analysis as encrypted on-device PyTorch models. Once
decrypted locally (into the gitignored `notes/models/`), several of them run on
the signals we already sync into `oura.db`. This page indexes the runners and what
each can and can't do.

## Tools

| tool | model(s) | output | status |
| --- | --- | --- | --- |
| `oura sessions` / `tools/run_activity_model.py` | `automatic_activity_detection_3_1_11` | activity/workout segments + type label | ✅ runs |
| `tools/run_sleep_model.py` | `sleepstaging_2_6_0` (NSSA, the official app's stager) | DEEP/LIGHT/REM/WAKE hypnogram per ring bedtime + efficiency | ✅ runs (custom ops + classifier, see [sleep-staging.md](algorithms/sleep-staging.md)) |
| `tools/run_bdi_model.py` (dashboard: `--batch`) / `run_models.py bdi` | `sleepnet_bdi_0_4_0` | breathing disturbances per night (ODI = % of sleep epochs flagged, events/h) + its own hypnogram | ✅ runs (iOS: `BreathingModel.swift`) |
| `tools/run_cva_model.py` | `cva_2_1_0` | cardiovascular (vascular) age + pulse-wave velocity | ✅ runs (needs `cva_ppg` on — see [cva-cardiovascular-age.md](cva-cardiovascular-age.md)) |
| `tools/run_spo2.py` | (no model — Oura's calibration) | overnight SpO2 % | ✅ runs (see [spo2-calibration.md](spo2-calibration.md)) |
| `tools/run_models.py daily_medians` | `daily_medians_1_1_0` | HRV/HR/temp/MET daily medians | ⚠️ runs but needs **awake** HRV (ours is nocturnal) |
| `tools/inspect_models.py` | all | dump each model's `forward()` schema | helper |

BDI's `sleepStages` col0 is the stage code (1 deep, 2 light, 3 REM, 4 awake) and its
softmax columns follow that order; its post-processor counts codes 1–2 as NREM. An
earlier note here read the columns as `[AWAKE, LIGHT, REM, DEEP]`, which contradicts
the model's own total-sleep figure. `outputMetrics` = `[bdi_status (2 when ODI ≥ 15),
status (1 ok, 3 sleep < 180 min, 4 IBI coverage < 70 %), total_sleep_min, odi, odi_nrem,
odi_rem]`, with ODI the percentage of sleep epochs flagged (not events per hour).

## What's blocked, and why (data availability, not wiring)

Of the ~26 newest-version models, most are blocked on a signal we can't get:

- **raw PPG waveform** — `cva_2_1_0` was here until `cva_ppg` was enabled (now
  `cva_raw_ppg_data` 0x81 supplies it). Still blocked for `halite` (needs the same
  raw PPG wired) and `whr` (needs raw PPG + raw accel).
- **raw ACM / stepmotion gait** — `step_counter`, `steps_motion_decoder`,
  `awhr_imputation`, `awhr_profile_selector` (RData-gated; entitlement-locked).
- **bioZ + EDA sensors** — `atlas` (not in our event stream).
- **cloud-computed scores** — `stress_resilience`, `training_stress_score`.
- **cycle / pregnancy inputs** — `popsicle`, `pregnancy_biometrics`.
- **pipeline deps** (need another model's / cloud output first) — `cumulative_stress`,
  `cva_calibrator`, `stress_daytime_sensing`.

(The full per-model matrix lives in the local-only `notes/model-usage-map.md`.)

## Model versions

Runners and the iOS app find a model by **family**, not exact file name: each names
the version its inputs were validated on and falls back to the newest local version
whose `forward()` takes the same inputs (`_common.resolve_model` with `oldest`/`newest`,
iOS `ModelFiles.known`), reporting the version it ran. Checked against the schemas:
`cva_2_1_5` stands in for 2.1.0 (same `(x, demographics)`), `cva_1_3_0` does not (4
inputs); AAD 3.1.12 stands in for 3.1.11, but 3.1.15 replaced the three scalar
thresholds with `global_settings`/`user_settings`/`activity_settings` tensors and fails
validation (error 18) with the 3.1.11 inputs, so it is excluded until a runner builds
those tensors.
`inspect_models.py` and `export_mobile.py` discover every file in `notes/models/`
(newest per family; `inspect_models.py --all-versions` for all), and
`inspect_models.py --json` is a weight-free schema dump that is safe to share.

## Notes
- All runners read `oura.db` by default and reference `notes/models/` (both
  gitignored — no model weights or personal data are committed).
- The models are Oura's proprietary, decrypted artifacts; they are **not** included
  in the repo. You supply your own locally.
