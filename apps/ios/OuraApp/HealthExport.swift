import Foundation
import Combine
import HealthKit
import Darwin

/// Writes ring-derived samples to Apple Health and removes ones we previously
/// saved that no longer exist (a dropped false-positive hike, a restaged night).
/// Off unless the user turns it on in Profile. All samples are tagged with a
/// sync identifier so Health can replace them and we can find them to delete.
final class HealthExport: ObservableObject {
    static let shared = HealthExport()
    private static let enabledKey = "health.export.enabled"
    private static let fingerprintKey = "health.export.fp"
    private static let pendingKey = "health.export.pending"
    private static let moveRingKey = "health.export.moveRing"
    /// The last export didn't land (typically: Health is unreadable while the phone
    /// is locked). The cached summary is retried once the phone unlocks.
    static var exportPending: Bool { UserDefaults.standard.bool(forKey: pendingKey) }
    private static let syncPrefix = "openoura."

    /// RMSSD and SDNN are different measurements. SDKs before iOS 27 do not
    /// declare RMSSD, so resolve the public constant only on supporting systems.
    static let ringHRVType: HKQuantityType? = {
        guard #available(iOS 27, *), let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD"),
              let value = symbol.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee else { return nil }
        let identifier = Unmanaged<NSString>.fromOpaque(value).takeUnretainedValue() as String
        return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
    }()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    /// Save active energy inside workouts so it counts toward Apple Fitness's Move
    /// ring. With an Apple Watch paired, Fitness ignores other apps' loose Active
    /// Energy and credits only energy that belongs to a workout. On by default.
    @Published var fillMoveRing: Bool {
        didSet {
            UserDefaults.standard.set(fillMoveRing, forKey: Self.moveRingKey)
            if enabled, let cached = SummaryCache.load() { push(cached) }
        }
    }
    static var fillsMoveRing: Bool { UserDefaults.standard.object(forKey: moveRingKey) as? Bool ?? true }
    @Published var status: String = ""
    @Published private(set) var lastExportAt: Date? = UserDefaults.standard.object(forKey: "health.export.at") as? Date

    private let store = HKHealthStore()
    private let queue = DispatchQueue(label: "md.thomas.openoura.health", qos: .utility)
    private var pushing = false

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        fillMoveRing = Self.fillsMoveRing
    }

    static var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .heartRate) { types.insert(t) }
        if let t = ringHRVType { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .respiratoryRate) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .vo2Max) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(t) }
        types.insert(HKSeriesType.heartbeat())
        return types
    }

    /// Previously authorized SDNN is queried only to remove this exporter's old
    /// RMSSD records. Do not request new SDNN write access for that cleanup.
    static func reconciliationTypes(canShare: (HKSampleType) -> Bool) -> Set<HKSampleType> {
        var types = shareTypes
        if let legacy = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN), canShare(legacy) {
            types.insert(legacy)
        }
        return types
    }

    static func legacyHRVSamples(_ samples: [HKObject]) -> [HKObject] {
        samples.filter { sample in
            guard let quantity = sample as? HKQuantitySample,
                  quantity.quantityType.identifier == HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
                  let id = syncID(sample) else { return false }
            return id.hasPrefix(syncPrefix + "hrv.")
        }
    }

    func setEnabled(_ on: Bool, summary: Summary?) {
        enabled = on
        guard on else {
            status = "Export paused. Samples already in Health are left in place."
            return
        }
        authorize { [weak self] ok, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.status = error.localizedDescription }
                return
            }
            guard ok else {
                DispatchQueue.main.async { self.status = "Apple Health write access was not granted." }
                return
            }
            if let summary { self.push(summary, force: true) }
            else if let cached = SummaryCache.load() { self.push(cached, force: true) }
            else { DispatchQueue.main.async { self.status = "On. Data will export after the next analysis." } }
        }
    }

    func push(_ summary: Summary, force: Bool = false) {
        guard enabled, summary.error == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let fp = Self.fingerprint(summary)
        if !force, fp == UserDefaults.standard.string(forKey: Self.fingerprintKey) { return }
        queue.async { [weak self] in
            guard let self, !self.pushing else { return }
            self.pushing = true
            defer { self.pushing = false }
            self.authorizeAndWrite(summary, fingerprint: fp)
        }
    }

    /// `push` for callers that must know when the write lands (a background task
    /// has to report completion). False when Health refused it, e.g. while locked.
    func pushAndWait(_ summary: Summary) async -> Bool {
        guard enabled, summary.error == nil, HKHealthStore.isHealthDataAvailable() else { return false }
        let fp = Self.fingerprint(summary)
        if fp == UserDefaults.standard.string(forKey: Self.fingerprintKey) { return true }
        return await withCheckedContinuation { completion in
            queue.async { [weak self] in
                guard let self, !self.pushing else { completion.resume(returning: false); return }
                self.pushing = true
                defer { self.pushing = false }
                completion.resume(returning: self.authorizeAndWrite(summary, fingerprint: fp))
            }
        }
    }

    /// The iPhone writes its own step count to Health through the day; observing it
    /// is a free, roughly hourly wake-up for a background sync. Our own step writes
    /// trigger it too, which BackgroundSync's minimum gap absorbs.
    static var wakeTypes: Set<HKObjectType> {
        HKObjectType.quantityType(forIdentifier: .stepCount).map { [$0] } ?? []
    }

    /// Must be registered at every launch, background ones included.
    func observeForWakeUps(_ onUpdate: @escaping (@escaping () -> Void) -> Void) {
        guard enabled, HKHealthStore.isHealthDataAvailable(),
              let steps = HKObjectType.quantityType(forIdentifier: .stepCount) else { return }
        let query = HKObserverQuery(sampleType: steps, predicate: nil) { _, completion, error in
            if let error { dlog("health", "step observer: \(error)"); completion(); return }
            onUpdate(completion)
        }
        store.execute(query)
        store.enableBackgroundDelivery(for: steps, frequency: .hourly) { ok, error in
            if !ok { dlog("health", "background delivery off: \(error.map { String(describing: $0) } ?? "unknown")") }
        }
    }

    func removeExportedSamples() {
        queue.async { [weak self] in
            guard let self else { return }
            let group = DispatchGroup()
            var errorText: String?
            for type in Self.reconciliationTypes(canShare: self.canShare) {
                group.enter()
                self.allOurs(type) { samples, error in
                    if let error { errorText = error.localizedDescription; group.leave(); return }
                    guard !samples.isEmpty else { group.leave(); return }
                    self.store.delete(samples) { _, err in
                        if let err { errorText = err.localizedDescription }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                UserDefaults.standard.removeObject(forKey: Self.fingerprintKey)
                self.status = errorText ?? "Removed Open Oura samples from Apple Health."
                dlog("health", self.status)
            }
        }
    }

    private func authorize(completion: @escaping (Bool, Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, NSError(domain: "open_oura", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Apple Health is unavailable on this device."]))
            return
        }
        store.requestAuthorization(toShare: Self.shareTypes, read: Self.wakeTypes) { ok, error in
            completion(ok, error)
        }
    }

    @discardableResult
    private func authorizeAndWrite(_ summary: Summary, fingerprint fp: String) -> Bool {
        let group = DispatchGroup()
        var authError: Error?
        var authOK = false
        group.enter()
        authorize { ok, error in
            authOK = ok
            authError = error
            group.leave()
        }
        group.wait()
        if let authError {
            DispatchQueue.main.async { self.status = authError.localizedDescription }
            UserDefaults.standard.set(true, forKey: Self.pendingKey)
            return false
        }
        guard authOK else {
            DispatchQueue.main.async { self.status = "Apple Health write access was not granted." }
            UserDefaults.standard.set(true, forKey: Self.pendingKey)
            return false
        }

        var samples = buildSamples(summary)
        var workouts = plannedWorkouts(summary.workouts)
        if Self.fillsMoveRing, canShare(HKObjectType.workoutType()) {
            (samples, workouts) = Self.moveRingPlan(samples: samples, workouts: workouts)
        }
        let beatSeries = plannedHeartbeats(Self.distinctNights(summary.nights))
        dlog("health", "export \(samples.count) samples, \(workouts.count) workouts, \(beatSeries.count) beat series")
        let types = Self.reconciliationTypes(canShare: canShare)
        let collect = DispatchGroup()
        let collectionLock = NSLock()
        var ours: [HKObject] = []
        var queryError: Error?
        for type in types {
            collect.enter()
            allOurs(type) { found, error in
                collectionLock.lock()
                if let error { queryError = error }
                ours.append(contentsOf: found)
                collectionLock.unlock()
                collect.leave()
            }
        }
        collect.wait()
        if let queryError {
            dlog("health", "export read failed: \(queryError)")
            DispatchQueue.main.async { self.status = queryError.localizedDescription }
            UserDefaults.standard.set(true, forKey: Self.pendingKey)
            return false
        }
        // Even a now-empty export must reconcile legacy HRV records.
        if samples.isEmpty, workouts.isEmpty, beatSeries.isEmpty, ours.isEmpty {
            DispatchQueue.main.async { self.status = "Nothing to export. Check Apple Health permissions for Open Oura." }
            UserDefaults.standard.set(false, forKey: Self.pendingKey)
            return false
        }

        let wantedIDs = Set(samples.compactMap(Self.syncID) + workouts.map(\.syncID) + workouts.compactMap(\.kcalSyncID)
                            + workouts.flatMap { $0.energy.compactMap(Self.syncID) }
                            + beatSeries.map(\.syncID))
        let stale = ours.filter { sample in
            guard let id = Self.syncID(sample) else { return true }
            return !wantedIDs.contains(id)
        }
        let existingIDs = Set(ours.compactMap(Self.syncID))
        let freshSamples = samples.filter {
            guard let id = Self.syncID($0) else { return true }
            return !existingIDs.contains(id)
        }
        let freshWorkouts = workouts.filter { !existingIDs.contains($0.syncID) }
        let freshBeats = beatSeries.filter { !existingIDs.contains($0.syncID) }

        let write = DispatchGroup()
        var writeError: Error?
        if !stale.isEmpty {
            write.enter()
            store.delete(stale) { _, error in
                if let error { writeError = error }
                write.leave()
            }
            write.wait()
        }
        if writeError == nil, !freshSamples.isEmpty {
            write.enter()
            store.save(freshSamples) { _, error in
                if let error { writeError = error }
                write.leave()
            }
            write.wait()
        }
        if writeError == nil {
            for workout in freshWorkouts {
                if let error = saveWorkout(workout) {
                    writeError = error
                    break
                }
            }
        }
        if writeError == nil {
            for series in freshBeats {
                if let error = saveHeartbeats(series) {
                    writeError = error
                    break
                }
            }
        }
        let added = freshSamples.count + freshWorkouts.count + freshBeats.count
        DispatchQueue.main.async {
            if let writeError {
                self.status = writeError.localizedDescription
                dlog("health", "export failed: \(writeError)")
            } else {
                UserDefaults.standard.set(fp, forKey: Self.fingerprintKey)
                self.lastExportAt = Date()
                UserDefaults.standard.set(self.lastExportAt, forKey: "health.export.at")
                self.status = "Exported \(added) new, removed \(stale.count) stale."
                dlog("health", self.status)
            }
        }
        UserDefaults.standard.set(writeError != nil, forKey: Self.pendingKey)
        return writeError == nil
    }

    private func allOurs(_ type: HKSampleType, completion: @escaping ([HKObject], Error?) -> Void) {
        let pred = HKQuery.predicateForObjects(from: HKSource.default())
        let query = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, error in
            let ours: [HKObject] = samples ?? []
            completion(ours, error)
        }
        store.execute(query)
    }

    static func fingerprint(_ s: Summary) -> String {
        // Force one reconciliation after upgrading from the mislabeled SDNN
        // writer, and another when the OS first supports the proper RMSSD type.
        var parts = ["hrv-rmssd-v1:\(ringHRVType?.identifier ?? "unavailable")", "move:\(fillsMoveRing)"]
        // Daytime HR comes from the event table, not the summary, so let an
        // otherwise unchanged summary still reconcile once per hour.
        parts.append("ids-v2:\(Int(Date().timeIntervalSince1970 / 3600)):\(s.fitness?.vo2max ?? 0)")
        parts.append(contentsOf: s.workouts.filter { $0.isWorkout >= 0.5 }.map { "\($0.id):\($0.kcal ?? -1)" }.sorted())
        for n in s.nights {
            let st = n.hypnogram ?? []
            parts.append("n\(n.start_ds ?? 0):\(st.count):\(st.reduce(0, +)):\(n.hrv_ms ?? 0):\(n.rhr ?? 0):\(n.spo2_mean ?? 0):\(n.breath_rate ?? 0):\(n.series?.hr.count ?? 0)")
        }
        for day in s.activity_daily.keys.sorted() {
            let st = s.activity_daily[day]!
            parts.append("d\(day):\(st.steps ?? 0):\(st.active_kcal ?? 0):\(st.distance_m ?? 0)")
        }
        return parts.joined(separator: "|")
    }

    private func buildSamples(_ s: Summary) -> [HKObject] {
        var out: [HKObject] = []
        let nights = Self.distinctNights(s.nights)
        for night in nights { out.append(contentsOf: sleepSamples(night)) }
        for night in nights { out.append(contentsOf: Self.heartSamples(night, canShare: canShare)) }
        out.append(contentsOf: dailySamples(s.activity_daily, slots: s.activity_slots,
                                            workoutMetKcal: Self.workoutMetKcal(s)))
        out.append(contentsOf: daytimeHeartSamples(nights: s.nights))
        out.append(contentsOf: fitnessSamples(s.fitness))
        return out
    }

    /// One sample per hour the ring logged beats outside sleep, at that hour's
    /// median (outlier beats would otherwise read as peaks). Night hours are left to
    /// `heartSamples`, which writes the sleep series at a finer step.
    private func daytimeHeartSamples(nights: [NightRow]) -> [HKObject] {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate), canShare(type) else { return [] }
        let hourly = HourlyHR.load(days: 3)
        if let error = hourly.error { dlog("health", "hourly HR unavailable: \(error)"); return [] }
        let asleep = nights.compactMap(Self.nightInterval)
        let unit = HKUnit.count().unitDivided(by: .minute())
        return hourly.bars.compactMap { bar -> HKObject? in
            let start = Date(timeIntervalSince1970: bar.unix)
            let end = start.addingTimeInterval(3600)
            guard bar.count > 0, bar.median > 20, bar.median < 220,
                  !asleep.contains(where: { start < $0.1 && end > $0.0 }) else { return nil }
            return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: bar.median),
                                    start: start, end: end,
                                    metadata: Self.meta("hrh.\(Int(bar.unix)).\(Int(bar.median.rounded()))"))
        }
    }

    /// The ring-derived VO2 max estimate, stamped on the day it was computed.
    private func fitnessSamples(_ fitness: Fitness?) -> [HKObject] {
        guard let type = HKObjectType.quantityType(forIdentifier: .vo2Max), canShare(type),
              let vo2 = fitness?.vo2max, vo2 > 10, vo2 < 90 else { return [] }
        // Timestamped when first estimated today, not at midnight; the sync id stays
        // per-day, so later exports the same day keep this sample.
        let day = Calendar.current.startOfDay(for: Date())
        let at = Date()
        let unit = HKUnit(from: "ml/kg*min")
        return [HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: vo2),
                                 start: at, end: at,
                                 metadata: Self.meta("vo2.\(Int(day.timeIntervalSince1970)).\(Int((vo2 * 10).rounded()))"))]
    }

    private static func meta(_ id: String) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: Self.syncPrefix + id,
         HKMetadataKeySyncVersion: 1]
    }

    private static func syncID(_ sample: HKObject) -> String? {
        sample.metadata?[HKMetadataKeySyncIdentifier] as? String
    }

    struct PlannedWorkout {
        let id: String
        let type: HKWorkoutActivityType
        let start: Date
        let end: Date
        /// Active kcal from Oura's energy model, attached to the workout.
        let kcal: Double?
        /// The day's 15-min Active Energy samples that fall in this workout, saved
        /// with it so Apple Fitness credits them to Move (see `moveRingPlan`).
        var energy: [HKQuantitySample] = []
        var energyKcal: Double { energy.reduce(0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) } }
        // A changed calorie figure replaces the workout instead of leaving the old one.
        var syncID: String {
            HealthExport.syncPrefix + "workout.\(id)" + (kcal.map { ".\(Int($0.rounded()))kcal" } ?? "")
                + (energy.isEmpty ? "" : ".\(Int((energyKcal * 10).rounded()))mv")
        }
        /// The calorie sample saved inside the workout; reconciled with it.
        var kcalSyncID: String? { kcal.map { HealthExport.syncPrefix + "workout-kcal.\(id).\(Int($0.rounded()))" } }
    }

    /// The MET estimate for each local day's model-scored workout minutes (the part
    /// of that day's Active Energy the workouts now carry themselves), from the same
    /// 15-min MET-above-rest profile as the daily figure: kcal = MET x kg x hours.
    static func workoutMetKcal(_ s: Summary) -> [String: [Double]] {
        let weight = s.profile?.weight_kg ?? 75
        var out: [String: [Double]] = [:]
        for w in s.workouts where w.isWorkout >= 0.5 && w.kcal != nil {
            guard let (start, end) = workoutDates(w) else { continue }
            var t = start
            while t < end {
                let day = Calendar.current.startOfDay(for: t)
                let key = Self.ymd(day)
                let bucket = Int(t.timeIntervalSince(day) / 900)
                let bucketEnd = min(end, day.addingTimeInterval(Double(bucket + 1) * 900))
                if let profile = s.activity_profile[key], bucket < profile.count, bucket < 96 {
                    out[key, default: Array(repeating: 0, count: 96)][bucket] +=
                        max(0, profile[bucket]) * weight * bucketEnd.timeIntervalSince(t) / 3600
                }
                t = bucketEnd
            }
        }
        return out
    }

    private static func ymd(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func plannedWorkouts(_ workouts: [WorkoutSession]) -> [PlannedWorkout] {
        guard canShare(HKObjectType.workoutType()) else { return [] }
        var out: [PlannedWorkout] = []
        for w in workouts where w.isWorkout >= 0.5 {
            guard let (start, end) = Self.workoutDates(w) else { continue }
            out.append(PlannedWorkout(id: w.id, type: Self.activityType(w.label), start: start, end: end, kcal: w.kcal))
        }
        return out
    }

    /// Bouts split where the ring logged no active energy for this long.
    static let moveBoutGap: TimeInterval = 30 * 60
    /// Smaller bouts stay loose Active Energy rather than become a workout each.
    static let moveBoutMinKcal = 5.0

    /// Apple Fitness's Move ring, with an Apple Watch paired, ignores other apps'
    /// loose Active Energy and counts only energy saved inside a workout. So the
    /// 15-min Active Energy samples move into workouts: into a detected workout when
    /// the slot's midpoint falls in it, otherwise into a "movement" bout (type Other)
    /// of consecutive active slots. Health's Active Energy total is unchanged; each
    /// sample is still saved once. Exercise and Stand can't be written by apps.
    static func moveRingPlan(samples: [HKObject], workouts: [PlannedWorkout])
        -> (samples: [HKObject], workouts: [PlannedWorkout]) {
        let slotPrefix = syncPrefix + "kcal15."
        var loose: [HKObject] = []
        var slots: [HKQuantitySample] = []
        for sample in samples {
            if let q = sample as? HKQuantitySample, syncID(q)?.hasPrefix(slotPrefix) == true {
                slots.append(q)
            } else {
                loose.append(sample)
            }
        }
        var planned = workouts
        var free: [HKQuantitySample] = []
        for slot in slots.sorted(by: { $0.startDate < $1.startDate }) {
            let mid = slot.startDate.addingTimeInterval(slot.endDate.timeIntervalSince(slot.startDate) / 2)
            if let w = planned.firstIndex(where: { $0.start <= mid && mid < $0.end }) {
                planned[w].energy.append(slot)
            } else {
                free.append(slot)
            }
        }
        var bouts: [[HKQuantitySample]] = []
        for slot in free {
            if let last = bouts.last?.last,
               slot.startDate.timeIntervalSince(last.endDate) < moveBoutGap,
               !planned.contains(where: { $0.start < slot.startDate && $0.end > last.endDate }) {
                bouts[bouts.count - 1].append(slot)
            } else {
                bouts.append([slot])
            }
        }
        for bout in bouts {
            guard let first = bout.first, let last = bout.last,
                  bout.reduce(0, { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }) >= moveBoutMinKcal else {
                loose.append(contentsOf: bout)
                continue
            }
            // kcal15.<day>.<slot>.<value> -> move.<day>.<slot>
            let parts = (syncID(first) ?? "").dropFirst(slotPrefix.count).split(separator: ".")
            let id = "move." + parts.prefix(2).joined(separator: ".") + ".\(bout.count)"
            planned.append(PlannedWorkout(id: id, type: .other, start: first.startDate, end: last.endDate,
                                          kcal: nil, energy: bout))
        }
        // Each sample is re-keyed to its workout, so a workout that changes takes its
        // energy with it, and clamped to the workout so the builder accepts it (a
        // slot's midpoint is inside its workout, so the clamp never empties it).
        for i in planned.indices where !planned[i].energy.isEmpty {
            let w = planned[i]
            let owner = String(w.syncID.dropFirst(syncPrefix.count))
            planned[i].energy = w.energy.map { s in
                let id = String((syncID(s) ?? "").dropFirst(syncPrefix.count))
                return HKQuantitySample(type: s.quantityType, quantity: s.quantity,
                                        start: max(s.startDate, w.start), end: min(s.endDate, w.end),
                                        metadata: meta("\(id).in.\(owner)"))
            }
        }
        return (loose, planned)
    }

    /// A run of consecutive ring beats inside one sleep, as Health's heartbeat series:
    /// the same beat-to-beat record the Apple Watch writes, from which readers such
    /// as Bevel compute HRV themselves.
    struct PlannedHeartbeats {
        let start: Date
        /// Seconds since `start` for each beat.
        let offsets: [Double]
        var syncID: String { HealthExport.syncPrefix + "beats.\(Int(start.timeIntervalSince1970 * 1000)).\(offsets.count)" }
    }

    /// Beat series are split where the ring paused (more than `maxGap` between valid
    /// beats) and capped at `maxSpan` like the Watch's short recordings.
    static let maxGap: Double = 2.5
    static let maxSpan: Double = 300
    static let minBeats = 30

    /// The summary can carry a night twice: once as the ring first postprocessed it
    /// mid-sleep, again when it finished. Exporting both would double the sleep in
    /// Health, so keep only the latest capture of any overlapping nights.
    static func distinctNights(_ nights: [NightRow]) -> [NightRow] {
        let newestFirst = nights.sorted {
            ($0.captured_unix ?? 0, $0.end_unix ?? 0) > ($1.captured_unix ?? 0, $1.end_unix ?? 0)
        }
        var kept: [NightRow] = []
        var spans: [(Date, Date)] = []
        for night in newestFirst {
            guard let span = nightInterval(night) else { continue }
            if spans.contains(where: { span.0 < $0.1 && span.1 > $0.0 }) { continue }
            kept.append(night); spans.append(span)
        }
        return kept
    }

    private func plannedHeartbeats(_ nights: [NightRow]) -> [PlannedHeartbeats] {
        guard canShare(HKSeriesType.heartbeat()) else { return [] }
        let windows = nights.compactMap(Self.nightInterval)
            .filter { Date().timeIntervalSince($0.1) < 4 * 86400 }
        guard !windows.isEmpty else { return [] }
        // The newest IBI events (6 beats each); a night is a few thousand of them.
        let json = eventsJson(dbPath: DB.readPath(), nameFilter: "ibi_and_amplitude_event", limit: 25_000)
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["events"] as? [[String: Any]] else { return [] }
        var events: [(Int64, [Int], [Int])] = rows.compactMap { row in
            guard let unix = (row["unix_s"] as? NSNumber)?.doubleValue,
                  let decoded = row["decoded"] as? [String: Any],
                  let ibis = (decoded["ibi_ms"] as? [NSNumber])?.map(\.intValue), ibis.count == 6 else { return nil }
            return (Int64(unix * 1000), ibis, (decoded["amplitude"] as? [NSNumber])?.map(\.intValue) ?? [])
        }
        events.sort { $0.0 < $1.0 }
        return Self.heartbeatSeries(events: events, windows: windows)
    }

    /// Pure: expand IBI events to beats, keep the ones Oura's own correction calls
    /// valid, and cut them into series inside the sleep windows.
    static func heartbeatSeries(events: [(Int64, [Int], [Int])], windows: [(Date, Date)]) -> [PlannedHeartbeats] {
        var raw: [(Int64, Int, Int)] = []
        var last: Int64 = 0
        for (t, ibis, amps) in events {
            let (beats, l) = NssaInputs.expandIbiEvent(ibis, amps, t, last)
            raw += beats; last = l
        }
        guard !raw.isEmpty else { return [] }
        let valid = IbiCorrection.correct(raw).filter { $0.3 == 1 }.map { Double($0.0) / 1000 }
        var out: [PlannedHeartbeats] = []
        for (from, to) in windows {
            let lo = from.timeIntervalSince1970, hi = to.timeIntervalSince1970
            var run: [Double] = []
            func flush() {
                if run.count >= minBeats, let first = run.first {
                    out.append(PlannedHeartbeats(start: Date(timeIntervalSince1970: first), offsets: run.map { $0 - first }))
                }
                run = []
            }
            for t in valid where t >= lo && t <= hi {
                if let prev = run.last, t - prev > maxGap || t <= prev || t - run[0] > maxSpan { flush() }
                run.append(t)
            }
            flush()
        }
        return out
    }

    private func saveHeartbeats(_ plan: PlannedHeartbeats) -> Error? {
        let builder = HKHeartbeatSeriesBuilder(healthStore: store, device: .local(), start: plan.start)
        let group = DispatchGroup()
        var failure: Error?
        for offset in plan.offsets {
            group.enter()
            builder.addHeartbeatWithTimeInterval(sinceSeriesStartDate: offset, precededByGap: false) { _, error in
                if let error { failure = error }
                group.leave()
            }
        }
        group.enter()
        builder.addMetadata(Self.meta(String(plan.syncID.dropFirst(Self.syncPrefix.count)))) { _, error in
            if let error { failure = error }
            group.leave()
        }
        group.wait()
        if let failure { return failure }
        group.enter()
        builder.finishSeries { _, error in
            if let error { failure = error }
            group.leave()
        }
        group.wait()
        return failure
    }

    /// Historical workouts must go through `HKWorkoutBuilder`; the old
    /// `HKWorkout(activityType:start:end:…)` initializers are deprecated.
    private func saveWorkout(_ plan: PlannedWorkout) -> Error? {
        let config = HKWorkoutConfiguration()
        config.activityType = plan.type
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        let group = DispatchGroup()
        var result: Error?
        func fail(_ error: Error?, fallback: String) {
            result = error ?? NSError(domain: "open_oura", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: fallback])
            group.leave()
        }
        group.enter()
        builder.beginCollection(withStart: plan.start) { success, error in
            guard success else { fail(error, fallback: "Could not start workout collection."); return }
            builder.addMetadata(Self.meta(String(plan.syncID.dropFirst(Self.syncPrefix.count)))) { success, error in
                guard success else { fail(error, fallback: "Could not tag workout."); return }
                func end() {
                    builder.endCollection(withEnd: plan.end) { success, error in
                        guard success else { fail(error, fallback: "Could not end workout collection."); return }
                        builder.finishWorkout { _, error in
                            result = error
                            group.leave()
                        }
                    }
                }
                // The workout's calories ride on the workout (Bevel and Fitness read them
                // there); the day's Active Energy sample leaves these minutes out.
                var energy = plan.energy
                if let kcal = plan.kcal, kcal > 0, let kcalID = plan.kcalSyncID,
                   let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned), self.canShare(type) {
                    energy.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                                                   start: plan.start, end: plan.end,
                                                   metadata: Self.meta(String(kcalID.dropFirst(Self.syncPrefix.count)))))
                }
                guard !energy.isEmpty else { end(); return }
                builder.add(energy) { success, error in
                    guard success else { fail(error, fallback: "Could not add workout calories."); return }
                    end()
                }
            }
        }
        group.wait()
        return result
    }

    /// The night's 30 s stages. Rings whose firmware stages sleep itself (Gen 3)
    /// send a hypnogram; newer firmware leaves staging to Oura's proprietary phone
    /// model, which this build doesn't ship. Without either, stage from the ring's
    /// overnight HR, HRV and motion (oura-summary's `stage_night_from_signals`), so
    /// Health still gets core/deep/REM/awake rather than an unstaged "In Bed".
    static func sleepStages(_ night: NightRow) -> (stages: [Int], estimated: Bool)? {
        if let stages = night.hypnogram, stages.count > 1 { return (stages, false) }
        guard night.hasSignals, let stages = Sleep.estimateStages(night: night),
              stages.contains(where: { (1...3).contains($0) }) else { return nil }
        return (stages, true)
    }

    private func sleepSamples(_ night: NightRow) -> [HKObject] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              canShare(type),
              let (start, end) = Self.nightInterval(night) else { return [] }
        var out: [HKObject] = []
        let key = "\(night.start_ds ?? 0)"
        out.append(HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                    start: start, end: end, metadata: Self.meta("sleep.inbed.\(key)")))
        guard let (stages, estimated) = Self.sleepStages(night) else { return out }
        let epoch = end.timeIntervalSince(start) / Double(stages.count)
        let runs = Self.sleepRuns(stages, estimated: estimated)
        dlog("health", "night \(key): \(runs.count) sleep runs\(estimated ? " (estimated, asleep/awake only)" : "")")
        for run in runs {
            let a = start.addingTimeInterval(Double(run.from) * epoch)
            let b = start.addingTimeInterval(Double(run.to) * epoch)
            var metadata = Self.meta("sleep.\(key).\(run.from).\(run.to).\(run.value.rawValue)")
            if estimated { metadata["OpenOuraStaging"] = "estimate" }
            out.append(HKCategorySample(type: type, value: run.value.rawValue, start: a, end: max(b, a.addingTimeInterval(1)),
                                        metadata: metadata))
        }
        return out
    }

    /// Consecutive epochs of one Health sleep value. A measured hypnogram keeps its
    /// stages; an estimated one only claims asleep vs awake, the part HR and motion
    /// can tell apart, so readers don't score deep/REM that was never measured.
    static func sleepRuns(_ stages: [Int], estimated: Bool) -> [(from: Int, to: Int, value: HKCategoryValueSleepAnalysis)] {
        func value(_ code: Int) -> HKCategoryValueSleepAnalysis? {
            switch code {
            case 1: return estimated ? .asleepUnspecified : .asleepDeep
            case 2: return estimated ? .asleepUnspecified : .asleepCore
            case 3: return estimated ? .asleepUnspecified : .asleepREM
            case 4: return .awake
            default: return nil
            }
        }
        var runs: [(from: Int, to: Int, value: HKCategoryValueSleepAnalysis)] = []
        var i = 0
        while i < stages.count {
            guard let v = value(stages[i]) else { i += 1; continue }
            var j = i + 1
            while j < stages.count, value(stages[j]) == v { j += 1 }
            runs.append((i, j, v))
            i = j
        }
        return runs
    }

    /// Sample construction is separate from HealthKit authorization and writes.
    static func heartSamples(_ night: NightRow, canShare: (HKSampleType) -> Bool) -> [HKObject] {
        var out: [HKObject] = []
        guard let (start, end) = Self.nightInterval(night) else { return out }
        let key = "\(night.start_ds ?? 0)"
        if let type = ringHRVType,
           canShare(type), let hrv = night.hrv_ms, hrv.isFinite, hrv > 0 {
            let q = HKQuantity(unit: .secondUnit(with: .milli), doubleValue: hrv)
            out.append(HKQuantitySample(type: type, quantity: q, start: end, end: end,
                                        metadata: meta("hrv.rmssd.\(key).\(Int(hrv.rounded()))")))
        }
        // Health's "Heart Rate Variability" chart, and apps reading HRV from Health
        // (Bevel among them), only see the SDNN type. The ring measures RMSSD; the
        // official Oura app files it under HRV all the same, so do what readers
        // expect: the in-sleep series at about 5-minute steps (as Oura writes it),
        // tagged with the real method. The nightly figure also goes to RMSSD above.
        if let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN), canShare(type) {
            let unit = HKUnit.secondUnit(with: .milli)
            let method: [String: Any] = ["OpenOuraHRVMethod": "RMSSD"]
            if let series = night.series?.hrv, series.count > 1 {
                let span = end.timeIntervalSince(start)
                let step = max(1, series.count / max(1, Int(span / 300)))
                var i = 0
                while i < series.count {
                    let ms = series[i]
                    if ms.isFinite, ms > 3, ms < 300 {
                        let t = start.addingTimeInterval(span * Double(i) / Double(series.count - 1))
                        out.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: ms),
                                                    start: t, end: t,
                                                    metadata: meta("hrvs.\(key).\(i).\(Int(ms.rounded()))").merging(method) { a, _ in a }))
                    }
                    i += step
                }
            } else if let hrv = night.hrv_ms, hrv.isFinite, hrv > 0 {
                out.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: hrv),
                                            start: end, end: end,
                                            metadata: meta("hrvs.\(key).night.\(Int(hrv.rounded()))").merging(method) { a, _ in a }))
            }
        }
        if let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate),
           canShare(type), let rhr = night.rhr, rhr > 0 {
            let q = HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: rhr)
            out.append(HKQuantitySample(type: type, quantity: q, start: end, end: end,
                                        metadata: meta("rhr.\(key).\(Int(rhr.rounded()))")))
        }
        if let type = HKObjectType.quantityType(forIdentifier: .oxygenSaturation),
           canShare(type), let spo2 = night.spo2_mean, spo2 >= 70, spo2 <= 100 {
            let q = HKQuantity(unit: .percent(), doubleValue: spo2 / 100)
            out.append(HKQuantitySample(type: type, quantity: q, start: start, end: end,
                                        metadata: meta("spo2.\(key).\(Int(spo2.rounded()))")))
        }
        if let type = HKObjectType.quantityType(forIdentifier: .respiratoryRate),
           canShare(type), let rate = night.breath_rate, rate > 4, rate < 40 {
            let q = HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: rate)
            out.append(HKQuantitySample(type: type, quantity: q, start: start, end: end,
                                        metadata: meta("resp.\(key).\(Int((rate * 10).rounded()))")))
        }
        if let type = HKObjectType.quantityType(forIdentifier: .heartRate), canShare(type),
           let series = night.series?.hr, series.count > 1 {
            let unit = HKUnit.count().unitDivided(by: .minute())
            let span = end.timeIntervalSince(start)
            let step = max(1, series.count / max(1, Int(span / 300)))
            var i = 0
            while i < series.count {
                let bpm = series[i]
                if bpm > 20, bpm < 220 {
                    let t = start.addingTimeInterval(span * Double(i) / Double(series.count - 1))
                    let q = HKQuantity(unit: unit, doubleValue: bpm)
                    out.append(HKQuantitySample(type: type, quantity: q, start: t, end: t,
                                                metadata: meta("hr.\(key).\(i).\(Int(bpm.rounded()))")))
                }
                i += step
            }
        }
        return out
    }

    private func dailySamples(_ daily: [String: DailyStat], slots: [String: ActivitySlots],
                              workoutMetKcal: [String: [Double]] = [:]) -> [HKObject] {
        Self.activitySamples(daily: daily, slots: slots, workoutMetKcal: workoutMetKcal, canShare: canShare)
    }

    /// Steps, active/basal energy and distance, placed in the 15-minute slots they
    /// happened in. Health readers chart samples at their start time, so a single
    /// midnight-to-midnight total showed the whole day at 12 am. Days without slot
    /// data (an older core) still get the daily total.
    /// `workoutMetKcal` (per day, per slot) is the MET energy of model-scored workout
    /// minutes; those workouts carry their own calories, so Active Energy leaves it out.
    static func activitySamples(daily: [String: DailyStat], slots: [String: ActivitySlots],
                                workoutMetKcal: [String: [Double]] = [:],
                                canShare: (HKSampleType) -> Bool, now: Date = Date()) -> [HKObject] {
        var out: [HKObject] = []
        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.calendar = cal
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = .current
        dayFmt.dateFormat = "yyyy-MM-dd"
        let steps = HKObjectType.quantityType(forIdentifier: .stepCount).flatMap { canShare($0) ? $0 : nil }
        let active = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned).flatMap { canShare($0) ? $0 : nil }
        let basal = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned).flatMap { canShare($0) ? $0 : nil }
        let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning).flatMap { canShare($0) ? $0 : nil }
        func add(_ type: HKQuantityType?, _ unit: HKUnit, _ value: Double, _ start: Date, _ end: Date, _ id: String) {
            guard let type, value > 0 else { return }
            out.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                                        start: start, end: end, metadata: meta(id)))
        }
        for (day, st) in daily {
            guard let start = dayFmt.date(from: day),
                  let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
            guard let slot = slots[day], slot.steps.count == 96, slot.active_kcal.count == 96,
                  slot.minutes.count == 96 else {
                add(steps, .count(), st.steps ?? 0, start, end, "steps.\(day).\(Int((st.steps ?? 0).rounded()))")
                let trimmed = max(0, (st.active_kcal ?? 0) - (workoutMetKcal[day]?.reduce(0, +) ?? 0))
                add(active, .kilocalorie(), trimmed, start, end, "kcal.\(day).\(Int(trimmed.rounded()))")
                if let total = st.total_kcal, let act = st.active_kcal {
                    add(basal, .kilocalorie(), total - act, start, end, "basal.\(day).\(Int((total - act).rounded()))")
                }
                add(distance, .meter(), st.distance_m ?? 0, start, end, "dist.\(day).\(Int((st.distance_m ?? 0).rounded()))")
                continue
            }
            for i in 0..<96 where slot.minutes[i] > 0 {
                // DST days are 23 or 25 h long; slots follow the wall clock like the core.
                guard let a = cal.date(byAdding: .minute, value: i * 15, to: start),
                      let b = cal.date(byAdding: .minute, value: (i + 1) * 15, to: start) else { continue }
                // A slot still in progress ends now, not in the future.
                let e = min(b, max(now, a.addingTimeInterval(1)))
                let key = "\(day).\(i)"
                let trims = workoutMetKcal[day]
                let s = slot.steps[i]
                let k = max(0, slot.active_kcal[i] - (trims.map { i < $0.count ? $0[i] : 0 } ?? 0))
                add(steps, .count(), s, a, e, "steps15.\(key).\(Int(s.rounded()))")
                add(active, .kilocalorie(), k, a, e, "kcal15.\(key).\(Int((k * 10).rounded()))")
                // ecore's walking distance, 0.762 m per step, as in the daily total.
                add(distance, .meter(), s * 0.762, a, e, "dist15.\(key).\(Int(s.rounded()))")
                if let perMin = slot.basal_kcal_per_min {
                    let kcal = perMin * Double(slot.minutes[i])
                    add(basal, .kilocalorie(), kcal, a, e, "basal15.\(key).\(Int((kcal * 10).rounded()))")
                }
            }
        }
        return out
    }

    private func canShare(_ type: HKSampleType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    private static func workoutDates(_ w: WorkoutSession) -> (Date, Date)? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let start = f.date(from: w.start) else { return nil }
        let day = String(w.start.prefix(10))
        guard var end = f.date(from: "\(day) \(w.end)") else { return nil }
        if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end }
        return (start, end)
    }

    private static func nightInterval(_ n: NightRow) -> (Date, Date)? {
        guard let ymd = n.ymd, let startHM = n.start, let endHM = n.end else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let start = f.date(from: "\(ymd) \(startHM)") else { return nil }
        var end = f.date(from: "\(ymd) \(endHM)") ?? start
        if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end }
        return (start, end)
    }

    private static func activityType(_ label: String) -> HKWorkoutActivityType {
        let l = label.lowercased()
        switch true {
        case l.contains("hik"): return .hiking
        case l.contains("walk"): return .walking
        case l.contains("run"): return .running
        case l.contains("cycl"), l.contains("bik"): return .cycling
        case l.contains("swim"): return .swimming
        case l.contains("row"): return .rowing
        case l.contains("strength"): return .traditionalStrengthTraining
        case l.contains("yoga"): return .yoga
        case l.contains("pilates"): return .pilates
        case l.contains("hiit"): return .highIntensityIntervalTraining
        case l.contains("elliptical"): return .elliptical
        case l.contains("ski"): return .crossCountrySkiing
        case l.contains("snowboard"): return .snowboarding
        case l.contains("climb"): return .climbing
        case l.contains("golf"): return .golf
        case l.contains("dance"): return .cardioDance
        case l.contains("box"): return .boxing
        case l.contains("martial"): return .martialArts
        default: return .other
        }
    }
}
