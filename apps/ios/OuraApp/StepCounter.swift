#if TORCH
import Foundation

/// Counted steps, the way the Oura app gets them: the ring's real-step gait packets
/// (0x7e/0x7f, one per 30 s while worn) are decoded by steps_motion_decoder into
/// 10-second windows, and Oura's step_counter turns each window into steps, using the
/// minute's 0x47 motion to reject typing, gestures and other non-walking movement.
/// Results are per local day in 96 × 15-minute slots and replace the core's MET-based
/// step estimate.
enum StepCounter {
    struct DayEntry: Codable {
        var fp: String
        var slots: [Double]
    }
    static let cacheFile = "step-counter-cache.json"
    private static let pipelineVersion = 1

    static var available: Bool {
        ModelFiles.find("step_counter") != nil && ModelFiles.find("steps_motion_decoder") != nil
    }

    private static var modelName: String {
        "steps-v\(pipelineVersion)|\(ModelFiles.find("step_counter")?.name ?? "-")|\(ModelFiles.find("steps_motion_decoder")?.name ?? "-")"
    }

    /// The last results without reading events (store unchanged since).
    static func cached() -> [String: [Double]] {
        guard available else { return [:] }
        let key = ModelCacheStore.globalKey(profile: nil, model: modelName)
        let cache: [String: DayEntry] = ModelCacheStore.load(cacheFile, globalKey: key)
        return cache.mapValues(\.slots)
    }

    /// Steps per local day and 15-minute slot. Days whose inputs are unchanged come
    /// from the cache; a day that fails is left out (no steps rather than a guess).
    static func run(events: EventStore.Events, clock: EventStore.RingClock) -> (days: [String: [Double]], error: String?) {
        guard let counterPath = ModelFiles.find("step_counter")?.path, available else {
            return ([:], "step counter model file missing from the app bundle")
        }
        let packets = ActivityModel.collectStepPackets(events: events, clock: clock)
        guard !packets.isEmpty else { return ([:], nil) }

        var motion: [(ms: Int64, values: [Float])] = []
        func number(_ value: Any?) -> Float { (value as? NSNumber)?.floatValue ?? 0 }
        for event in events.restricted("tag=71") {
            guard let seconds = clock.datedUnixSeconds(event.ds, capturedUnix: event.cu) else { continue }
            let minute = (seconds / 60).rounded()
            motion.append((Int64(minute * 60_000), [
                number(event.json["orientation"]), number(event.json["motion_seconds"]),
                number(event.json["avg_x"]), number(event.json["avg_y"]), number(event.json["avg_z"]),
                .nan, number(event.json["low_intensity"]), number(event.json["high_intensity"]),
            ]))
        }
        motion.sort { $0.ms < $1.ms }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let dayFmt = DateFormatter()
        dayFmt.calendar = calendar
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = .current
        dayFmt.dateFormat = "yyyy-MM-dd"
        func day(_ unixMinute: Double) -> Date { calendar.startOfDay(for: Date(timeIntervalSince1970: unixMinute * 60)) }

        let byDay = Dictionary(grouping: packets) { day($0.unixMinute) }
        let key = ModelCacheStore.globalKey(profile: nil, model: modelName)
        var cache: [String: DayEntry] = ModelCacheStore.load(cacheFile, globalKey: key)
        var out: [String: [Double]] = [:]
        var failed: [String] = []
        for (dayStart, dayPackets) in byDay.sorted(by: { $0.key > $1.key }) {
            if AnalysisRun.cancelled { break }
            let label = dayFmt.string(from: dayStart)
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let lo = Int64(dayStart.timeIntervalSince1970 * 1000), hi = Int64(next.timeIntervalSince1970 * 1000)
            // The model pairs each window with motion up to 30 s away.
            let dayMotion = motion.filter { $0.ms >= lo - 60_000 && $0.ms < hi + 60_000 }
            let sorted = dayPackets.sorted { $0.unixMinute < $1.unixMinute }
            let fp = "\(sorted.count):\(Int64((sorted.last?.unixMinute ?? 0) * 60_000)):\(dayMotion.count):\(dayMotion.last?.ms ?? 0)"
            if let hit = cache[label], hit.fp == fp, hit.slots.count == 96 {
                out[label] = hit.slots
                continue
            }
            do {
                let gait = try ActivityModel.decodeStepPackets(sorted)
                var slots = [Double](repeating: 0, count: 96)
                if !gait.isEmpty {
                    var ts = gait.map { Int64(($0.unixMinute * 60_000).rounded()) }
                    var data = gait.flatMap(\.values)
                    var mts = dayMotion.map(\.ms)
                    var mdata = dayMotion.flatMap(\.values)
                    var starts = [Int64](repeating: 0, count: gait.count)
                    var steps = [Float](repeating: 0, count: gait.count)
                    let n = oura_step_counter(counterPath, &ts, &data, Int32(gait.count),
                                              &mts, &mdata, Int32(dayMotion.count),
                                              &starts, &steps, Int32(gait.count))
                    guard n >= 0 else { throw ActivityModel.InferenceFailure.bridge() }
                    for i in 0..<Int(n) where steps[i].isFinite && steps[i] > 0 {
                        let ms = starts[i]
                        guard ms >= lo, ms < hi else { continue }
                        let minutes = Double(ms - lo) / 60_000
                        // Wall-clock slot, matching the core's local-day buckets.
                        let slot = min(95, max(0, Int(minutes / 15)))
                        slots[slot] += Double(steps[i])
                    }
                }
                slots = slots.map { ($0 * 10).rounded() / 10 }
                cache[label] = DayEntry(fp: fp, slots: slots)
                out[label] = slots
            } catch {
                dlog("models", "steps day=\(label) failed: \(error)")
                failed.append(label)
            }
        }
        ModelCacheStore.save(cacheFile, globalKey: key, entries: cache)
        let total = out.values.reduce(0) { $0 + $1.reduce(0, +) }
        dlog("models", "steps days=\(out.count) errors=\(failed.count) total=\(Int(total))")
        return (out, failed.isEmpty ? nil : "step counter failed for \(failed.sorted().joined(separator: ", "))")
    }

    /// Replace the core's MET-based steps (and the distance derived from them) with
    /// counted steps. With the counter bundled, a day it has no result for gets no
    /// steps at all: the estimate is not a step count.
    static func apply(_ days: [String: [Double]], to s: inout Summary) {
        var labels = Set(days.keys)
        labels.formUnion(s.activity_daily.keys)
        for label in labels {
            let counted = days[label] ?? [Double](repeating: 0, count: 96)
            var slot = s.activity_slots[label] ?? ActivitySlots(
                active_kcal: Array(repeating: 0, count: 96), steps: [],
                minutes: Array(repeating: 0, count: 96), basal_kcal_per_min: nil)
            slot.steps = counted
            s.activity_slots[label] = slot
            let total = counted.reduce(0, +)
            var daily = s.activity_daily[label] ?? DailyStat()
            daily.steps = total.rounded()
            daily.distance_m = (total * 0.762).rounded()
            s.activity_daily[label] = daily
        }
    }
}
#endif
