import HealthKit
import XCTest
@testable import OuraApp

/// Constructs samples only: no HealthKit permissions, queries, saves or deletes.
final class HealthExportTests: XCTestCase {
    func testRingHrvReachesBothHrvTypes() {
        var night = NightRow(ymd: "2026-10-10", start_ds: 100, start: "23:00", end: "07:00")
        night.hrv_ms = 72
        night.rhr = 50
        let samples = HealthExport.heartSamples(night, canShare: { _ in true })
            .compactMap { $0 as? HKQuantitySample }
        // Readers of Health's HRV chart only see the SDNN type, so the ring's RMSSD
        // goes there too (as the official app does), tagged with its real method.
        let sdnn = samples.first { $0.quantityType.identifier == HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue }
        XCTAssertEqual(sdnn?.metadata?["OpenOuraHRVMethod"] as? String, "RMSSD")
        XCTAssertTrue(samples.contains { $0.quantityType.identifier == HKQuantityTypeIdentifier.restingHeartRate.rawValue })
        let hrv = samples.first { ($0.metadata?[HKMetadataKeySyncIdentifier] as? String)?.hasPrefix("openoura.hrv.") == true }
        if let expectedType = HealthExport.ringHRVType {
            XCTAssertEqual(hrv?.quantityType, expectedType)
            XCTAssertEqual(hrv?.quantity.doubleValue(for: .secondUnit(with: .milli)), 72)
            XCTAssertEqual(hrv?.metadata?[HKMetadataKeySyncIdentifier] as? String, "openoura.hrv.rmssd.100.72")
        } else {
            XCTAssertNil(hrv)
        }
        XCTAssertTrue(HealthExport.heartSamples(night, canShare: { _ in false }).isEmpty)
    }

    func testAuthorizationRequestsBothHrvTypes() throws {
        let sdnn = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN))
        XCTAssertTrue(HealthExport.shareTypes.contains(sdnn))
        if let rmssd = HealthExport.ringHRVType { XCTAssertTrue(HealthExport.shareTypes.contains(rmssd)) }
    }

    func testLegacyCleanupSelectsOnlyOurTaggedSdnnRecords() throws {
        let sdnn = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN))
        let rhr = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .restingHeartRate))
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func sample(_ type: HKQuantityType, _ id: String?) -> HKQuantitySample {
            HKQuantitySample(type: type, quantity: HKQuantity(unit: type == sdnn ? .secondUnit(with: .milli) : .count().unitDivided(by: .minute()),
                                                           doubleValue: 60), start: at, end: at,
                             metadata: id.map { [HKMetadataKeySyncIdentifier: $0, HKMetadataKeySyncVersion: 1] })
        }
        let legacy = sample(sdnn, "openoura.hrv.100")
        let legitimate = sample(sdnn, "another-export.sdnn.100")
        let untagged = sample(sdnn, nil)
        let otherMetric = sample(rhr, "openoura.hrv.100")
        XCTAssertEqual(HealthExport.legacyHRVSamples([legacy, legitimate, untagged, otherMetric]).map(\.uuid), [legacy.uuid])
    }

    func testChangedValuesGetNewSyncIdentifiers() {
        // Reconciliation keys on sync identifiers, so a value that changes between
        // background syncs (a re-staged night, a revised RHR) must change its ID.
        var night = NightRow(ymd: "2026-10-10", start_ds: 100, start: "23:00", end: "07:00")
        night.rhr = 50
        night.spo2_mean = 96
        night.breath_rate = 14.2
        func ids(_ n: NightRow) -> Set<String> {
            Set(HealthExport.heartSamples(n, canShare: { _ in true })
                .compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String })
        }
        let before = ids(night)
        XCTAssertTrue(before.contains("openoura.spo2.100.96"))
        XCTAssertTrue(before.contains("openoura.resp.100.142"))
        night.rhr = 52
        XCTAssertNotEqual(before, ids(night))
    }

    func testHeartbeatSeriesStayInsideSleepAndSplitLikeTheWatch() {
        // 20 minutes of steady 60 bpm beats in 6-beat ring events, a 30 s dropout,
        // and a window that starts a minute after the first beat.
        let t0: Int64 = 1_790_000_000_000
        var events: [(Int64, [Int], [Int])] = []
        var end = t0
        for k in 0..<200 {
            if k == 100 { end += 30_000 }
            end += 6_000
            events.append((end, Array(repeating: 1000, count: 6), Array(repeating: 800, count: 6)))
        }
        let window = (Date(timeIntervalSince1970: Double(t0) / 1000 + 60),
                      Date(timeIntervalSince1970: Double(end) / 1000))
        let series = HealthExport.heartbeatSeries(events: events, windows: [window])
        XCTAssertFalse(series.isEmpty)
        for s in series {
            XCTAssertGreaterThanOrEqual(s.offsets.count, HealthExport.minBeats)
            XCTAssertGreaterThanOrEqual(s.start, window.0)
            XCTAssertLessThanOrEqual(s.offsets.last ?? 0, HealthExport.maxSpan)
            XCTAssertEqual(s.offsets, s.offsets.sorted())
            for (a, b) in zip(s.offsets, s.offsets.dropFirst()) { XCTAssertLessThanOrEqual(b - a, HealthExport.maxGap) }
        }
        XCTAssertTrue(HealthExport.heartbeatSeries(events: events, windows: []).isEmpty)
    }

    func testHrvMigrationInvalidatesOldExportFingerprint() {
        // Before this fix an empty summary had an empty fingerprint, so an
        // unchanged dataset could skip the cleanup forever after an app upgrade.
        XCTAssertNotEqual(HealthExport.fingerprint(Summary()), "")
        XCTAssertEqual(HealthExport.fingerprint(Summary()), HealthExport.fingerprint(Summary()))
    }

    func testOnlyOuraStagedNightsReachHealthWithStages() {
        // A night Oura's model didn't stage gets no stages, however much HR and motion
        // it has: Health keeps only its In Bed window.
        var night = NightRow(ymd: "2026-10-10", start_ds: 100, start: "23:00", end: "07:00")
        night.series_t = NightTimedSeries(hr: [[0, 55], [300, 50]], hrv: [[0, 40], [300, 60]], motion: [[0, 1]])
        XCTAssertNil(HealthExport.sleepStages(night))
        night.stages_full = [2, 2, 1, 3, 4]
        night.staging_source = "signals"
        XCTAssertNil(HealthExport.sleepStages(night))
        night.staging_source = "nssa"
        XCTAssertEqual(HealthExport.sleepStages(night), [2, 2, 1, 3, 4])
        night.staging_source = "ring"
        XCTAssertEqual(HealthExport.sleepStages(night), [2, 2, 1, 3, 4])
    }

    func testSleepRunsKeepOurasStages() {
        let runs = HealthExport.sleepRuns([4, 4, 2, 1, 1, 3, 0, 2, 4])
        XCTAssertEqual(runs.map(\.value), [.awake, .asleepCore, .asleepDeep, .asleepREM, .asleepCore, .awake])
        XCTAssertEqual(runs.map(\.from), [0, 2, 3, 5, 7, 8])
    }

    func testWorkoutMetKcalCoversOnlyModelScoredWorkoutMinutes() {
        var s = Summary()
        s.profile = Profile(sex: "M", age: 30, height_m: 1.8, weight_kg: 80, ring_size: 10)
        var profile = [Double](repeating: 0, count: 96)
        profile[40] = 4  // 10:00-10:15
        profile[41] = 2  // 10:15-10:30
        s.activity_profile = ["2026-10-26": profile]
        var walk = WorkoutSession(start: "2026-10-26 10:00", end: "10:30", durationMin: 30, label: "walking", isWorkout: 0.9)
        walk.kcal = 120
        // A workout without the model's calories keeps its minutes in the daily sample.
        let other = WorkoutSession(start: "2026-10-26 10:15", end: "10:30", durationMin: 15, label: "running", isWorkout: 0.9)
        s.workouts = [walk, other]
        let trims = HealthExport.workoutMetKcal(s)
        // (4 MET x 80 kg x 0.25 h) + (2 MET x 80 kg x 0.25 h)
        XCTAssertEqual(trims["2026-10-26"]?.reduce(0, +) ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(trims["2026-10-26"]?[40] ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(trims["2026-10-26"]?[41] ?? 0, 40, accuracy: 0.001)
        // Each workout's own MET estimate, shown beside the model's calories.
        XCTAssertEqual(s.metKcal(walk) ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(s.metKcal(other) ?? 0, 40, accuracy: 0.001)
        let unprofiled = WorkoutSession(start: "2026-10-27 10:00", end: "10:30", durationMin: 30, label: "walking", isWorkout: 0.9)
        XCTAssertNil(s.metKcal(unprofiled))
    }

    func testActivityLandsInItsQuarterHourNotAtMidnight() throws {
        var slot = ActivitySlots(active_kcal: Array(repeating: 0, count: 96),
                                 steps: Array(repeating: 0, count: 96),
                                 minutes: Array(repeating: 0, count: 96), basal_kcal_per_min: 1.2)
        slot.steps[56] = 255; slot.active_kcal[56] = 4.5; slot.minutes[56] = 4
        slot.minutes[57] = 15
        let daily = ["2026-05-28": DailyStat(active_kcal: 5, total_kcal: 1700, steps: 300, distance_m: 229)]
        let samples = HealthExport.activitySamples(daily: daily, slots: ["2026-05-28": slot],
                                                   canShare: { _ in true }, now: .distantFuture)
            .compactMap { $0 as? HKQuantitySample }
        let start = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 28, hour: 14)))
        let steps = samples.filter { $0.quantityType.identifier == HKQuantityTypeIdentifier.stepCount.rawValue }
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.startDate, start)
        XCTAssertEqual(steps.first?.endDate, start.addingTimeInterval(15 * 60))
        XCTAssertEqual(steps.first?.quantity.doubleValue(for: .count()), 255)
        // Worn but idle: basal energy only, for the minutes the ring reported.
        let basal = samples.filter { $0.quantityType.identifier == HKQuantityTypeIdentifier.basalEnergyBurned.rawValue }
        XCTAssertEqual(basal.map { $0.quantity.doubleValue(for: .kilocalorie()) }.sorted(), [4.8, 18])
        XCTAssertFalse(samples.contains { Calendar.current.component(.hour, from: $0.startDate) == 0 })

        // An older core without slots still gets the daily totals.
        let legacy = HealthExport.activitySamples(daily: daily, slots: [:], canShare: { _ in true })
        XCTAssertEqual(legacy.count, 4)
    }
}
