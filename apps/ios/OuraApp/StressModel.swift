#if TORCH
import Foundation

/// Daytime stress with Oura's stress_daytime_sensing_1_1_0, one awake HRV sample at a
/// time. Twin of tools/run_stress_model.py (which see for the model's I/O contract):
/// the ring's RMSSD averages (0x5d, walked back from the packet stamp), its bedtime
/// windows (0x76) and per-minute MET (0x50), all on the dated wall clock in unix ms.
/// Baselines are trailing-14-day medians per local day; the last 14 days are scored.
/// The result is cached against the store digest, like the Symptom Radar.
enum StressModel {
    static let cacheFile = "stress-model-cache.json"
    private static let baselineDays = 14
    private static let maxDays = 14
    private static let minAwakeForBaseline = 3
    private static let defaultMet: Float = 1.0
    private static let day = 86400.0

    private static var model: ModelFiles.Found? { ModelFiles.find("stress_daytime_sensing") }
    private static func globalKey() -> String? {
        model.map { ModelCacheStore.globalKey(profile: nil, model: $0.name) }
    }

    /// The last complete run's answer when the store is unchanged; a missing model is
    /// a settled no-result, so it never forces the event read.
    static func cachedRun(storeDigest: String?) -> (result: DaytimeStress?, error: String?)? {
        guard let gk = globalKey() else { return (nil, nil) }
        guard let storeDigest, ModelCacheStore.loadDigest(cacheFile, globalKey: gk) == storeDigest else { return nil }
        let cached: [String: FingerprintedEntry<DaytimeStress>] = ModelCacheStore.load(cacheFile, globalKey: gk)
        return (cached["result"]?.value, nil)
    }

    static func run(events: EventStore.Events, clock: EventStore.RingClock,
                    knownDigest: String? = nil) -> (result: DaytimeStress?, error: String?) {
        guard let model, let gk = globalKey() else { return (nil, nil) } // not bundled: soft skip
        let storeDigest = knownDigest ?? events.digest()
        if let hit = cachedRun(storeDigest: storeDigest) { return hit }
        func dated(_ ds: Int64, _ cu: Int64) -> Double? { clock.datedUnixSeconds(ds, capturedUnix: cu) }
        let tz = Double(TimeZone.current.secondsFromGMT())
        func dayIndex(_ t: Double) -> Int { Int(((t + tz) / day).rounded(.down)) }

        // ── gather: bedtimes (ms), per-minute MET, RMSSD samples ─────────────────
        var bedtimes = Set<[Double]>()
        var met: [Int: Float] = [:]
        var hrvByTime: [Int: (t: Double, r: Double, step: Double)] = [:]
        for e in events.restricted("tag IN (80,93,118)") {
            switch e.tag {
            case 0x76:
                guard let s = (e.json["bedtime_start_ds"] as? NSNumber)?.int64Value,
                      let en = (e.json["bedtime_end_ds"] as? NSNumber)?.int64Value, en > s,
                      let us = dated(s, e.cu), let ue = dated(en, e.cu) else { continue }
                bedtimes.insert([(us * 1000).rounded(), (ue * 1000).rounded()])
            case 0x50:
                guard let base = dated(e.ds, e.cu), let arr = e.json["met"] as? [Any] else { continue }
                let minute = Int((base / 60).rounded())
                for (i, x) in arr.enumerated() { met[minute + i] = (x as? NSNumber)?.floatValue ?? 0 }
            case 0x5D:
                guard let base = dated(e.ds, e.cu), let rm = e.json["rmssd_ms"] as? [Any] else { continue }
                let step = ((e.json["interval_min"] as? NSNumber)?.doubleValue ?? 5) * 60
                // Stamped at the LAST average; earlier ones walk back by `step`.
                for (i, x) in rm.enumerated() {
                    let r = (x as? NSNumber)?.doubleValue ?? 0
                    guard r > 0 else { continue }
                    let t = base - Double(rm.count - 1 - i) * step
                    hrvByTime[Int(t.rounded())] = (t, r, step)
                }
            default: break
            }
        }
        guard events.error == nil, !AnalysisRun.cancelled else { return (nil, "stress: event read failed") }

        let beds = bedtimes.sorted { $0[0] < $1[0] }
        func asleep(_ t: Double) -> Bool { beds.contains { $0[0] <= t * 1000 && t * 1000 <= $0[1] } }
        let hrv = hrvByTime.values.sorted { $0.t < $1.t }
        let night = hrv.filter { asleep($0.t) }.map { (day: dayIndex($0.t), r: $0.r) }
        let awake = hrv.filter { !asleep($0.t) }
        func finish(_ result: DaytimeStress?) -> (result: DaytimeStress?, error: String?) {
            var entries: [String: FingerprintedEntry<DaytimeStress>] = [:]
            if let result { entries["result"] = FingerprintedEntry(fp: model.name, value: result) }
            ModelCacheStore.save(cacheFile, globalKey: gk, entries: entries, digest: storeDigest)
            return (result, nil)
        }
        guard !beds.isEmpty, !night.isEmpty, let newest = awake.last.map({ dayIndex($0.t) }) else { return finish(nil) }
        let first = newest - (maxDays - 1)

        func median(_ v: [Double]) -> Double {
            let s = v.sorted(); let n = s.count
            return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
        }
        var baselineMemo: [Int: (Double, Double, Bool)?] = [:]
        func baselines(_ d: Int) -> (night: Double, awake: Double, fromAwake: Bool)? {
            if let hit = baselineMemo[d] { return hit.map { ($0.0, $0.1, $0.2) } }
            let lo = d - (baselineDays - 1)
            let n = night.filter { $0.day >= lo && $0.day <= d }.map(\.r)
            let a = awake.filter { let x = dayIndex($0.t); return x >= lo && x <= d }.map(\.r)
            let value: (Double, Double, Bool)? = n.isEmpty ? nil
                : (median(n), a.count >= minAwakeForBaseline ? median(a) : median(n), a.count >= minAwakeForBaseline)
            baselineMemo[d] = value
            return value.map { ($0.0, $0.1, $0.2) }
        }

        let bedStart = beds.map { $0[0] }, bedEnd = beds.map { $0[1] }
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.timeZone = TimeZone(secondsFromGMT: 0)
        dateFmt.dateFormat = "yyyy-MM-dd"
        var samples: [StressSample] = [], rejected: [String: Int] = [:], imputed = 0, failures = 0
        var days: [Int: StressDay] = [:], scaled: [Int: [Double]] = [:]
        for s in awake {
            guard !AnalysisRun.cancelled else { break }
            let d = dayIndex(s.t)
            guard d >= first else { continue }
            guard let b = baselines(d) else { rejected["no night HRV baseline", default: 0] += 1; continue }
            let hi = Int((s.t / 60).rounded())
            let span = max(1, Int((s.step / 60).rounded()))
            let mets = (hi - span + 1...hi).compactMap { met[$0] }
            var m = defaultMet
            if mets.isEmpty { imputed += 1 } else { m = mets.reduce(0, +) / Float(mets.count) }
            var out = [Float](repeating: .nan, count: 8)
            let rc = oura_stress(model.path, Float(s.r), (s.t * 1000).rounded(), bedStart, bedEnd, Int32(beds.count),
                                 Float(b.awake), Float(b.night), m, &out)
            guard rc == 0 else {
                if rc > 0 { rejected["code \(rc)", default: 0] += 1 } else { failures += 1 }
                continue
            }
            func r3(_ v: Float) -> Double { (Double(v) * 1000).rounded() / 1000 }
            let zone = out[0] <= out[1] ? "stressed" : out[0] >= out[2] ? "restored" : "neutral"
            let minutes = Int((s.step / 60).rounded())
            samples.append(StressSample(unix: s.t.rounded(), minutes: minutes, dhrv: s.r,
                                        met: (Double(m) * 100).rounded() / 100, zone: zone,
                                        intensity: r3(out[0]), intensity_scaled: r3(out[5]),
                                        stress_limit: r3(out[1]), recovery_limit: r3(out[2]),
                                        stress_limit_scaled: r3(out[6]), recovery_limit_scaled: r3(out[7])))
            var row = days[d] ?? StressDay(date: dateFmt.string(from: Date(timeIntervalSince1970: Double(d) * day)),
                                           stressed_min: 0, restored_min: 0, neutral_min: 0, samples: 0,
                                           night_hrv_baseline: (b.night * 10).rounded() / 10,
                                           dhrv_baseline: (b.awake * 10).rounded() / 10,
                                           baseline_source: b.fromAwake ? "awake median" : "night fallback",
                                           mean_intensity_scaled: 0)
            switch zone {
            case "stressed": row.stressed_min += minutes
            case "restored": row.restored_min += minutes
            default: row.neutral_min += minutes
            }
            row.samples += 1
            days[d] = row
            scaled[d, default: []].append(Double(out[5]))
        }
        if AnalysisRun.cancelled { return (nil, "analysis interrupted") }
        for (d, v) in scaled { days[d]?.mean_intensity_scaled = (v.reduce(0, +) / Double(v.count) * 1000).rounded() / 1000 }
        dlog("models", "stress awake=\(awake.count) scored=\(samples.count) rejected=\(rejected) errors=\(failures)")
        if samples.isEmpty && failures > 0 { return (nil, "stress model failed") }
        return finish(DaytimeStress(model: model.name, awake_hrv_samples: awake.count, night_hrv_samples: night.count,
                                    met_imputed: imputed, neutral_zone_ms: samples.last?.recovery_limit,
                                    days: days.keys.sorted().compactMap { days[$0] }, samples: samples,
                                    rejected: rejected))
    }
}
#endif
