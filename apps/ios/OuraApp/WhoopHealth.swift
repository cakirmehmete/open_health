import Foundation
import HealthKit

/// Writes WHOOP-derived heart rate (per minute), HRV (one reading an hour) and
/// resting heart rate (per day) to Apple Health, from the seconds in WhoopStore.
///
/// Kept apart from HealthExport, which rebuilds and reconciles the ring's samples
/// from a summary: WHOOP samples are append-only, carry `openwhoop.` sync
/// identifiers (HealthExport leaves those alone), and are written once, tracked by
/// per-metric watermarks. Only settled time is exported (two minutes behind the
/// newest second, whole hours for HRV, whole days for resting HR), so a sample
/// never has to be rewritten when more of the same minute arrives.
///
/// HRV: Health's HRV chart and readers such as Bevel only read the SDNN type, and
/// the ring's exporter files its RMSSD there (as the Oura app does). WHOOP's own
/// figure is RMSSD too, so the same value goes in the same slot, tagged with the
/// method, keeping the two devices comparable; it also goes to the RMSSD type on
/// systems that have one.
final class WhoopHealth: ObservableObject, @unchecked Sendable {
    static let shared = WhoopHealth()
    static let syncPrefix = "openwhoop."
    /// Never reach further back than this, whatever the watermarks say.
    static let maxBackfill: UInt32 = 15 * 86_400

    @Published private(set) var lastExportAt: Date? = UserDefaults.standard.object(forKey: Key.at) as? Date
    @Published private(set) var status = ""

    private enum Key {
        static let hr = "whoop.health.hr"
        static let hrv = "whoop.health.hrv"
        static let rhr = "whoop.health.rhr"
        static let at = "whoop.health.at"
    }

    private let health = HKHealthStore()
    private let queue = DispatchQueue(label: "md.thomas.openoura.whoop.health", qos: .utility)
    private var running = false

    static var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = []
        for id in [HKQuantityTypeIdentifier.heartRate, .restingHeartRate, .heartRateVariabilitySDNN] {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if let rmssd = HealthExport.ringHRVType { types.insert(rmssd) }
        return types
    }

    /// Ask for write access. Call from the foreground (the sheet can't show otherwise).
    func authorize(completion: ((Bool) -> Void)? = nil) {
        guard HKHealthStore.isHealthDataAvailable() else { completion?(false); return }
        health.requestAuthorization(toShare: Self.shareTypes, read: []) { ok, error in
            if let error { dlog("whoop", "health authorization: \(error)") }
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    /// Export everything settled since the last run. Completes on main with whether
    /// Health is up to date (true when there was nothing to write).
    func export(firmware: String?, completion: ((Bool) -> Void)? = nil) {
        let enabled = HealthExport.shared.enabled
        queue.async { [self] in
            guard enabled, HKHealthStore.isHealthDataAvailable(), !running else {
                DispatchQueue.main.async { completion?(!enabled) }
                return
            }
            running = true
            let ok = exportNow(firmware: firmware)
            running = false
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    private func exportNow(firmware: String?) -> Bool {
        let newest = WhoopStore.shared.newest
        guard newest > 120 else { return true }
        let settled = newest - 120
        let floor = settled > Self.maxBackfill ? settled - Self.maxBackfill : 0
        let defaults = UserDefaults.standard
        var hrMark = max(UInt32(defaults.integer(forKey: Key.hr)), floor - floor % 60)
        var hrvMark = max(UInt32(defaults.integer(forKey: Key.hrv)), floor - floor % 3600)
        let calendar = Calendar.current
        var rhrMark = max(UInt32(defaults.integer(forKey: Key.rhr)),
                          UInt32(calendar.startOfDay(for: date(floor)).timeIntervalSince1970))
        let hrEnd = settled - settled % 60
        let hrvEnd = settled - settled % 3600
        guard hrMark < hrEnd || hrvMark < hrvEnd || rhrMark + 86_400 <= settled else { return true }

        // Authorization is decided in the foreground; here just respect it.
        let types = Self.shareTypes.filter { health.authorizationStatus(for: $0) == .sharingAuthorized }
        func type(_ id: HKQuantityTypeIdentifier) -> HKQuantityType? {
            HKObjectType.quantityType(forIdentifier: id).flatMap { types.contains($0) ? $0 : nil }
        }
        guard !types.isEmpty else {
            publish("Apple Health hasn't allowed WHOOP heart data yet. Tap Connect WHOOP to ask again.")
            return false
        }
        let device = HKDevice(name: "WHOOP", manufacturer: "WHOOP", model: "5.0", hardwareVersion: nil,
                              firmwareVersion: firmware, softwareVersion: nil, localIdentifier: nil,
                              udiDeviceIdentifier: nil)
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let msUnit = HKUnit.secondUnit(with: .milli)
        let rmssdType = HealthExport.ringHRVType.flatMap { types.contains($0) ? $0 : nil }

        var day = calendar.startOfDay(for: date(min(hrMark, hrvMark, rhrMark)))
        var written = 0
        while UInt32(day.timeIntervalSince1970) < settled {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let start = UInt32(day.timeIntervalSince1970), end = UInt32(next.timeIntervalSince1970)
            let seconds = WhoopStore.shared.samples(from: start, to: min(end, settled))
            var objects: [HKObject] = []
            let minutes = WhoopMetrics.minutes(seconds)

            if let hr = type(.heartRate) {
                for m in minutes where m.start >= hrMark && m.start + 60 <= hrEnd {
                    let context: HKHeartRateMotionContext = m.still ? .sedentary : .active
                    objects.append(HKQuantitySample(type: hr, quantity: HKQuantity(unit: bpmUnit, doubleValue: m.bpm),
                                                    start: date(m.start), end: date(m.start + 60), device: device,
                                                    metadata: meta("hr.\(m.start)",
                                                                   [HKMetadataKeyHeartRateMotionContext: context.rawValue])))
                }
            }
            let hrvSeconds = seconds.filter { $0.unix >= hrvMark && $0.unix < hrvEnd }
            for reading in WhoopMetrics.hourlyHRV(hrvSeconds) {
                if let sdnn = type(.heartRateVariabilitySDNN) {
                    objects.append(HKQuantitySample(type: sdnn, quantity: HKQuantity(unit: msUnit, doubleValue: reading.rmssd),
                                                    start: date(reading.start), end: date(reading.end), device: device,
                                                    metadata: meta("hrv.\(reading.start)", ["OpenOuraHRVMethod": "RMSSD"])))
                }
                if let rmssdType {
                    objects.append(HKQuantitySample(type: rmssdType, quantity: HKQuantity(unit: msUnit, doubleValue: reading.rmssd),
                                                    start: date(reading.start), end: date(reading.end), device: device,
                                                    metadata: meta("hrv.rmssd.\(reading.start)")))
                }
            }
            let dayComplete = end <= settled
            if dayComplete, start >= rhrMark, let rhr = type(.restingHeartRate),
               let value = WhoopMetrics.restingHeartRate(minutes) {
                objects.append(HKQuantitySample(type: rhr, quantity: HKQuantity(unit: bpmUnit, doubleValue: value),
                                                start: day, end: next, device: device, metadata: meta("rhr.\(start)")))
            }

            if !objects.isEmpty {
                if let error = save(objects) {
                    // Usually the phone being locked; the watermarks stay, so the next run retries.
                    publish("Health write pending: \(error.localizedDescription)")
                    dlog("whoop", "health save failed: \(error)")
                    return false
                }
                written += objects.count
            }
            hrMark = max(hrMark, min(hrEnd, end))
            hrvMark = max(hrvMark, min(hrvEnd, end))
            if dayComplete { rhrMark = max(rhrMark, end) }
            defaults.set(Int(hrMark), forKey: Key.hr)
            defaults.set(Int(hrvMark), forKey: Key.hrv)
            defaults.set(Int(rhrMark), forKey: Key.rhr)
            day = next
        }
        let now = Date()
        defaults.set(now, forKey: Key.at)
        let through = DateFormatter.localizedString(from: date(hrMark), dateStyle: .short, timeStyle: .short)
        DispatchQueue.main.async {
            self.lastExportAt = now
            self.status = "Wrote \(written) WHOOP samples, heart rate through \(through)."
        }
        dlog("whoop", "health export wrote \(written) samples through \(through)")
        return true
    }

    private func save(_ objects: [HKObject]) -> Error? {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        health.save(objects) { _, error in failure = error; done.signal() }
        done.wait()
        return failure
    }

    private func meta(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        extra.merging([HKMetadataKeySyncIdentifier: Self.syncPrefix + id,
                       HKMetadataKeySyncVersion: 1]) { $1 }
    }

    private func date(_ unix: UInt32) -> Date { Date(timeIntervalSince1970: TimeInterval(unix)) }

    private func publish(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }
}
