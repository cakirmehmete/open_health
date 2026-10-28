import XCTest
@testable import OuraApp

/// EcoreBreathing.swift must match tools/ecore_breathing_rate.py record for record. The
/// fixture (tools/make_ecore_breathing_fixture.py) holds the nights whose outputs and
/// record hashes the Python test checks against Oura's native libecore.
final class EcoreBreathingTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: EcoreBreathingTests.self).url(forResource: "EcoreBreathingFixture", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func ints(_ v: Any?) -> [Int] { (v as? [NSNumber])?.map(\.intValue) ?? [] }

    func testRecordsAndOutputMatchNativeVerifiedPython() throws {
        let cases = try XCTUnwrap(fixture()["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let seed = c["seed"] as! NSNumber
            let bedtime = (c["bedtime_ms"] as! NSNumber).int64Value
            let ibi = ints(c["ibi"]), ts = (c["ts"] as! [NSNumber]).map(\.int64Value), motion = ints(c["motion"])
            let records = EcoreBreathing.epochRecords(bedtimeStartMs: bedtime, ibi: ibi, timestampsMs: ts, motionSeconds: motion)
            let want = c["records"] as! [[NSNumber]]
            XCTAssertEqual(records.count, want.count, "seed \(seed)")
            for (i, (r, w)) in zip(records, want).enumerated() {
                let got = [Int(r.timeMs), r.heartRate, r.breathingRate, r.variability, r.motion, r.status]
                if got != w.map(\.intValue) {
                    XCTFail("seed \(seed) record \(i): \(got) != \(w)")
                    break
                }
            }
            let out = EcoreBreathing.calculate(bedtimeStartMs: bedtime, ibi: ibi, timestampsMs: ts, motionSeconds: motion)
            let expected = (c["output"] as! [NSNumber]).map { Float($0.doubleValue) }
            XCTAssertEqual([out.breathingRate, out.variability, out.heartRate], expected, "seed \(seed)")
        }
    }

    func testFixmathHelpers() throws {
        let f = try XCTUnwrap(fixture()["fix16"] as? [String: Any])
        for row in try XCTUnwrap(f["div"] as? [[NSNumber]]) {
            XCTAssertEqual(EcoreBreathing.fix16Div(row[0].intValue, row[1].intValue), row[2].intValue, "div \(row)")
        }
        for row in try XCTUnwrap(f["sqrt"] as? [[NSNumber]]) {
            XCTAssertEqual(EcoreBreathing.fix16Sqrt(row[0].intValue), row[1].intValue, "sqrt \(row)")
        }
        XCTAssertEqual(EcoreBreathing.fix16Mul(0x18000, 0x18000), 0x24000)
        XCTAssertEqual(EcoreBreathing.fix16Mul(0x7FFF0000, 0x20000), EcoreBreathing.fix16Overflow)
        XCTAssertEqual(EcoreBreathing.fix16Add(0x7FFF0000, 0x10000), EcoreBreathing.fix16Overflow)
    }

    func testMotionPerEpochAlignment() throws {
        let m = try XCTUnwrap(fixture()["motion_per_epoch"] as? [String: Any])
        let events = (m["events"] as! [[NSNumber]]).map { ($0[0].int64Value, $0[1].intValue) }
        let got = EcoreBreathing.motionPerEpoch(bedtimeStartMs: (m["bedtime_ms"] as! NSNumber).int64Value,
                                                epochCount: (m["epochs"] as! NSNumber).intValue, events: events)
        XCTAssertEqual(got, ints(m["expected"]))
    }
}
