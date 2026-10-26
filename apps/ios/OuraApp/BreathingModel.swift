#if TORCH
import Foundation

/// Breathing disturbances per night with Oura's SleepNet-BDI (sleepnet_bdi_0_4_0).
/// Twin of tools/run_bdi_model.py: the night's longest ring bedtime (or the window
/// itself), its ecore-corrected beats exactly as NSSA reads them, one forward pass.
/// Results are cached per night window and model file, so a pass only runs new nights.
enum BreathingModel {
    static let cacheFile = "breathing-model-cache.json"
    private static let minBeats = 60
    private static let maxNights = 14

    private static var model: ModelFiles.Found? { ModelFiles.find("sleepnet_bdi") }
    private static func key(_ n: NightRow) -> String { "\(n.stagingKey):\(n.end_ds ?? 0)" }
    private static func globalKey() -> String? {
        model.map { ModelCacheStore.globalKey(profile: nil, timezone: false, model: $0.name) }
    }

    /// Saved results for these nights, keyed by `NightRow.stagingKey`; no event read.
    static func cached(nights: [NightRow]) -> [String: Breathing] {
        guard let gk = globalKey() else { return [:] }
        let cache: [String: FingerprintedEntry<Breathing?>] = ModelCacheStore.load(cacheFile, globalKey: gk)
        var out: [String: Breathing] = [:]
        for n in nights { if let b = cache[key(n)]?.value { out[n.stagingKey] = b } }
        return out
    }

    static func run(nights: [NightRow], events: EventStore.Events, clock: EventStore.RingClock)
        -> (results: [String: Breathing], error: String?) {
        guard let model, let gk = globalKey() else { return ([:], nil) } // not bundled: soft skip
        var cache: [String: FingerprintedEntry<Breathing?>] = ModelCacheStore.load(cacheFile, globalKey: gk)
        let wanted = nights.filter { $0.start_ds != nil && $0.end_ds != nil }.prefix(maxNights)
        guard wanted.contains(where: { cache[key($0)] == nil }) else { return (cached(nights: Array(wanted)), nil) }

        func ms(_ ds: Int64, _ cu: Int64) -> Int64 {
            Int64((clock.unixSeconds(ds, capturedUnix: cu) * 1000).rounded(.toNearestOrEven))
        }
        var rows: [NssaInputs.Row] = [], bedtimes: [NssaInputs.Row] = []
        for e in events.restricted("tag IN (96,118)") {
            let r = NssaInputs.Row(ds: e.ds, tag: e.tag, json: e.json, cu: e.cu, body: e.body.map { [UInt8]($0) })
            if e.tag == NssaInputs.tagBedtime { bedtimes.append(r) } else { rows.append(r) }
        }
        guard events.error == nil else { return ([:], "breathing: event read failed") }

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

        var failures = 0
        for night in wanted where cache[key(night)] == nil {
            guard !AnalysisRun.cancelled else { break }
            guard let startDs = night.start_ds, let endDs = night.end_ds else { continue }
            let cu = night.captured_unix ?? events.last?.cu ?? 0
            guard clock.datedUnixSeconds(startDs, capturedUnix: cu) != nil,
                  clock.datedUnixSeconds(endDs, capturedUnix: cu) != nil else { continue }
            let (bs, be) = mainBedtime(startDs, endDs, cu)
            let inp = NssaInputs.collect(rows: rows, startDs: bs, endDs: be, capturedUnix: cu, unixMs: ms)
            var value: Breathing? = nil
            if inp.ibi.count >= minBeats, inp.ibi.contains(where: { $0.3 == 1 }) {
                var ts = inp.ibi.map(\.0)
                var vals = inp.ibi.flatMap { [Float($0.1), Float($0.2), Float($0.3)] }
                var metrics = [Float](repeating: .nan, count: 6)
                var epochs: Int32 = 0, flagged: Int32 = 0
                if oura_bdi(model.path, inp.bedtime.0, inp.bedtime.1, &ts, &vals, Int32(inp.ibi.count),
                            &metrics, &epochs, &flagged) == 0 {
                    value = Breathing(metrics: metrics, flagged: Int(flagged), model: model.name)
                } else {
                    failures += 1
                }
            }
            cache[key(night)] = FingerprintedEntry(fp: model.name, value: value)
        }
        ModelCacheStore.save(cacheFile, globalKey: gk, entries: cache)
        dlog("models", "breathing nights=\(wanted.count) failed=\(failures)")
        let results = cached(nights: Array(wanted))
        return (results, results.isEmpty && failures > 0 ? "breathing model failed" : nil)
    }
}

extension Breathing {
    /// From oura_bdi's metrics [bdi_status, status, total_sleep_min, odi, odi_nrem, odi_rem].
    init(metrics m: [Float], flagged: Int, model: String) {
        func v(_ i: Int) -> Double? { i < m.count && !m[i].isNaN ? Double(m[i]) : nil }
        let sleepMin = v(2)
        self.init(status: v(1).map { Int($0) }, elevated: v(0).map { $0 == 2 },
                  total_sleep_min: sleepMin, odi_pct: v(3), odi_nrem_pct: v(4), odi_rem_pct: v(5),
                  flagged_epochs: flagged,
                  events_per_hour: sleepMin.flatMap { $0 > 0 ? Double(flagged) / ($0 / 60) : nil },
                  model: model)
    }
}
#endif
