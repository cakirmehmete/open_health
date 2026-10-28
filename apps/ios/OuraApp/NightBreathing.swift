#if TORCH
import Foundation

/// Nightly breathing rate with Oura's ecore algorithm (EcoreBreathing), per summary night.
/// Twin of tools/run_breathing_rate.py: the night's longest ring bedtime (as BreathingModel
/// and run_bdi_model.py pick it), its ecore-corrected beats exactly as NSSA reads them, and
/// 0x47 motion seconds per 30 s epoch. Pure integer/float code, no model file, so it runs
/// in every torch build. Results are cached per night window.
enum NightBreathing {
    static let cacheFile = "ecore-breathing-cache.json"
    static let version = "ecore-br-1"
    private static let maxNights = 45     // the Symptom Radar reads 30 wake days
    private static let tagMotion = 0x47

    struct Result: Codable { var rate: Double; var variability: Double; var heartRate: Double; var epochs: Int }

    private static func key(_ n: NightRow) -> String { "\(n.stagingKey):\(n.end_ds ?? 0)" }
    private static var globalKey: String { ModelCacheStore.globalKey(profile: nil, timezone: false, model: version) }

    /// Saved results for these nights, keyed by `NightRow.stagingKey`; no event read.
    static func cached(nights: [NightRow]) -> [String: Result] {
        let cache: [String: FingerprintedEntry<Result?>] = ModelCacheStore.load(cacheFile, globalKey: globalKey)
        var out: [String: Result] = [:]
        for n in nights { if let r = cache[key(n)]?.value { out[n.stagingKey] = r } }
        return out
    }

    static func run(nights: [NightRow], events: EventStore.Events, clock: EventStore.RingClock)
        -> (results: [String: Result], error: String?) {
        var cache: [String: FingerprintedEntry<Result?>] = ModelCacheStore.load(cacheFile, globalKey: globalKey)
        let wanted = Array(nights.filter { $0.start_ds != nil && $0.end_ds != nil }.prefix(maxNights))
        guard wanted.contains(where: { cache[key($0)] == nil }) else { return (cached(nights: wanted), nil) }

        func ms(_ ds: Int64, _ cu: Int64) -> Int64 {
            Int64((clock.unixSeconds(ds, capturedUnix: cu) * 1000).rounded(.toNearestOrEven))
        }
        var rows: [NssaInputs.Row] = [], bedtimes: [NssaInputs.Row] = []
        var motion: [(ds: Int64, cu: Int64, seconds: Int)] = []
        for e in events.restricted("tag IN (96,118,71)") {
            if e.tag == tagMotion {
                motion.append((e.ds, e.cu, (e.json["motion_seconds"] as? NSNumber)?.intValue ?? 0))
                continue
            }
            let r = NssaInputs.Row(ds: e.ds, tag: e.tag, json: e.json, cu: e.cu, body: e.body.map { [UInt8]($0) })
            if e.tag == NssaInputs.tagBedtime { bedtimes.append(r) } else { rows.append(r) }
        }
        guard events.error == nil else { return ([:], "ecore breathing: event read failed") }

        /// run_bdi_model.main_bedtime: the longest ring bedtime in the window, same boot.
        func mainBedtime(_ startDs: Int64, _ endDs: Int64, _ captured: Int64) -> (Int64, Int64) {
            var latest: [Int64: (Int64, Int64)] = [:]
            for r in bedtimes {
                guard let s = (r.json["bedtime_start_ds"] as? NSNumber)?.int64Value,
                      let e = (r.json["bedtime_end_ds"] as? NSNumber)?.int64Value, e > s,
                      abs(ms(s, r.cu) - ms(s, captured)) <= 300_000 else { continue }
                if s < endDs && e > startDs { latest[s] = (s, e) }
            }
            return latest.values.max { ($0.1 - $0.0) < ($1.1 - $1.0) } ?? (startDs, endDs)
        }

        var computed = 0
        for night in wanted where cache[key(night)] == nil {
            guard !AnalysisRun.cancelled else { break }
            guard let startDs = night.start_ds, let endDs = night.end_ds else { continue }
            let cu = night.captured_unix ?? events.last?.cu ?? 0
            guard clock.datedUnixSeconds(startDs, capturedUnix: cu) != nil,
                  clock.datedUnixSeconds(endDs, capturedUnix: cu) != nil else { continue }
            let (bs, be) = mainBedtime(startDs, endDs, cu)
            let inp = NssaInputs.collect(rows: rows, startDs: bs, endDs: be, capturedUnix: cu, unixMs: ms)
            let (startMs, endMs) = inp.bedtime
            let epochs = max(0, Int((endMs - startMs) / 30_000))
            var value: Result? = nil
            if epochs > 360, !inp.ibi.isEmpty {
                let nightMotion = motion.filter { bs <= $0.ds && $0.ds <= be }
                    .map { (ms($0.ds, $0.cu), $0.seconds) }
                    .sorted { $0.0 < $1.0 }
                let perEpoch = EcoreBreathing.motionPerEpoch(bedtimeStartMs: startMs, epochCount: epochs, events: nightMotion)
                let out = EcoreBreathing.calculate(bedtimeStartMs: startMs, ibi: inp.ibi.map(\.1),
                                                   timestampsMs: inp.ibi.map(\.0), motionSeconds: perEpoch)
                if out.breathingRate > 0 {
                    value = Result(rate: Double(out.breathingRate), variability: Double(out.variability),
                                   heartRate: Double(out.heartRate), epochs: epochs)
                }
            }
            cache[key(night)] = FingerprintedEntry(fp: version, value: value)
            computed += 1
        }
        ModelCacheStore.save(cacheFile, globalKey: globalKey, entries: cache)
        let results = cached(nights: wanted)
        dlog("models", "ecore breathing nights=\(wanted.count) computed=\(computed) with_rate=\(results.count)")
        return (results, nil)
    }

    /// Oura's breathing rate per wake date, longest night wins (the Symptom Radar input).
    static func byWakeDate(_ results: [String: Result], nights: [NightRow], summary: Summary) -> [String: Double] {
        var best: [String: (dur: Int64, rate: Double)] = [:]
        for n in nights {
            guard let r = results[n.stagingKey], let wake = summary.wakeYmd(n) else { continue }
            let dur = (n.end_ds ?? 0) - (n.start_ds ?? 0)
            if best[wake].map({ dur > $0.dur }) ?? true { best[wake] = (dur, r.rate) }
        }
        return best.mapValues(\.rate)
    }
}
#endif
