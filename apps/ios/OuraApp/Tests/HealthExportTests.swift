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

    func testUnstagedNightGetsStagesFromSignals() throws {
        // Newer ring firmware sends no hypnogram; the night still reaches Health staged.
        var night = NightRow(ymd: "2026-10-10", start_ds: 100, start: "23:00", end: "07:00")
        let start: Int64 = 1_791_000_000, end = start + 8 * 3600
        night.start_unix = start
        night.end_unix = end
        var series = NightTimedSeries()
        for (i, t) in stride(from: Double(start), through: Double(end), by: 300).enumerated() {
            let phase = (t - Double(start)) / Double(end - start)
            series.hr.append([t, 56 - 10 * sin(phase * .pi)])
            series.hrv.append([t, 45 + 30 * sin(phase * .pi)])
            series.motion.append([t, i % 37 == 0 ? 9 : 1])
        }
        night.series_t = series
        let (stages, estimated) = try XCTUnwrap(HealthExport.sleepStages(night))
        XCTAssertTrue(estimated)
        XCTAssertEqual(stages.count, 960)
        XCTAssertTrue(stages.contains { (1...3).contains($0) })

        night.stages_full = [2, 2, 1, 3, 4]
        XCTAssertEqual(HealthExport.sleepStages(night)?.estimated, false)
        XCTAssertNil(HealthExport.sleepStages(NightRow(ymd: "2026-10-10", start_ds: 100, start: "23:00", end: "07:00")))
    }
}
