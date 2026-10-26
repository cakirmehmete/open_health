import XCTest
@testable import OuraApp

/// WHOOP 5.0 framing, records and metrics. Bytes only: no Bluetooth or HealthKit.
final class WhoopTests: XCTestCase {
    func testChecksumsMatchThePublishedWorkedExample() {
        XCTAssertEqual(WhoopWire.crc16Modbus([0xAA, 0x01, 0x0C, 0x00, 0x00, 0x01]), 0x41E7)
        XCTAssertEqual(WhoopWire.crc32([0x23, 0xF1, 0x6A, 0x01, 0x01, 0x00, 0x00, 0x00]), 0xFC61_E958)
    }

    func testClientHelloIsGetHelloSequenceOne() {
        XCTAssertEqual(WhoopWire.command(WhoopCommand.getHello.rawValue, seq: 1, body: [0x01]), WhoopWire.clientHello)
    }

    func testCommandBodiesArePaddedToFourBytes() {
        let frame = WhoopWire.command(WhoopCommand.sendHistory.rawValue, seq: 7, body: [0x00])
        XCTAssertEqual(Array(frame[8..<12]), [0x23, 7, 22, 0])
        XCTAssertEqual(frame.count, 8 + 4 + 4)
        let ack = WhoopWire.command(WhoopCommand.historyResult.rawValue, seq: 8, body: WhoopMeta.ackBody([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(ack.count, 8 + 12 + 4)
        XCTAssertEqual(Array(ack[11..<20]), [1, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testClockBody() {
        let body = WhoopCommand.clockBody(Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(body, [0x01] + WhoopWire.le32(1_700_000_000) + WhoopWire.le16(16_384))
    }

    func testReassemblerJoinsFragmentsAndSkipsNoise() {
        let first = WhoopWire.frame(payload: [0x24, 9, 146, 3, 1, 0, 0, 0])
        let second = WhoopWire.frame(payload: [0x24, 10, 22, 4, 1, 0, 0, 0])
        var corrupt = WhoopWire.frame(payload: [0x24, 11, 26, 5, 1, 0, 0, 0])
        corrupt[12] ^= 0xFF
        let stream = [0x00, 0x13] + first + corrupt + second
        var assembler = WhoopWire.Reassembler()
        var frames: [[UInt8]] = []
        for chunk in stride(from: 0, to: stream.count, by: 7) {
            frames += assembler.append(Data(stream[chunk..<min(chunk + 7, stream.count)]))
        }
        XCTAssertEqual(frames, [first, second])
        let response = WhoopResponse(frame: frames[0])
        XCTAssertEqual(response?.command, 146)
        XCTAssertEqual(response?.originSeq, 3)
        XCTAssertEqual(response?.result, .success)
    }

    func testR18RecordDecodes() throws {
        var payload = [UInt8](repeating: 0, count: WhoopSample.frameLength - 12)
        func put(_ bytes: [UInt8], at frameOffset: Int) {
            for (i, b) in bytes.enumerated() { payload[frameOffset - 8 + i] = b }
        }
        put([WhoopPacket.historical, 18], at: 8)
        put(WhoopWire.le32(4242), at: 11)
        put(WhoopWire.le32(1_760_000_000), at: 15)
        put([58, 2], at: 22)
        put(WhoopWire.le16(1024) + WhoopWire.le16(1075), at: 24)
        put(WhoopWire.le16(123), at: 57)
        put([0], at: 63)
        put(WhoopWire.le16(3412), at: 73)
        let frame = WhoopWire.frame(payload: payload)
        XCTAssertEqual(frame.count, WhoopSample.frameLength)

        let sample = try XCTUnwrap(WhoopSample(r18: frame))
        XCTAssertEqual(sample.unix, 1_760_000_000)
        XCTAssertEqual(sample.index, 4242)
        XCTAssertEqual(sample.bpm, 58)
        XCTAssertEqual(sample.intervals, [1000, 1050])
        XCTAssertEqual(sample.activity, 0)
        XCTAssertEqual(sample.skinTempCenti, 3412)
        XCTAssertEqual(sample.steps, 123)

        let stored = sample.encoded()
        XCTAssertEqual(stored.count, WhoopSample.storedLength)
        XCTAssertEqual(WhoopSample(stored: stored, at: 0), sample)
        XCTAssertNil(WhoopSample(r18: Array(frame.dropLast())))
    }

    func testMetadataCarriesTheAckBlock() {
        var payload = [UInt8](repeating: 0, count: 24)
        payload[0] = WhoopPacket.metadata5
        payload[2] = 2
        for i in 0..<8 { payload[13 + i] = UInt8(0xA0 + i) }
        XCTAssertEqual(WhoopMeta(frame: WhoopWire.frame(payload: payload)),
                       .end(block: [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7]))
        payload[2] = 3
        XCTAssertEqual(WhoopMeta(frame: WhoopWire.frame(payload: payload)), .complete)
    }

    func testStoreRoundTripsAndDeduplicates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WhoopStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let day: UInt32 = 1_760_000_000 - 1_760_000_000 % 86_400
        let rows = (0..<5).map { WhoopSample(unix: day - 2 + UInt32($0), bpm: UInt8(60 + $0)) }
        try store.append(rows)
        try store.append([rows[3]])
        let back = store.samples(from: day - 2, to: day + 3)
        XCTAssertEqual(back.map(\.unix), rows.map(\.unix))
        XCTAssertEqual(store.samples(from: day, to: day + 1).map(\.bpm), [62])
    }

    func testHrvFromAlternatingBeats() throws {
        let beats = (0..<200).map { $0 % 2 == 0 ? 1000.0 : 1050.0 }
        let hrv = try XCTUnwrap(WhoopMetrics.hrv(beats))
        XCTAssertEqual(hrv.rmssd, 50, accuracy: 0.001)
        XCTAssertEqual(hrv.sdnn, 25.06, accuracy: 0.01)
        XCTAssertNil(WhoopMetrics.hrv(Array(beats.prefix(50))))
        // An ectopic beat is dropped along with the jumps around it.
        var ectopic = beats
        ectopic[100] = 600
        XCTAssertEqual(try XCTUnwrap(WhoopMetrics.hrv(ectopic)).rmssd, 50, accuracy: 0.001)
    }

    func testMinutesHourlyHrvAndRestingHeartRate() {
        let hour: UInt32 = 1_760_000_400 - 1_760_000_400 % 3600
        var seconds: [WhoopSample] = []
        for t in 0..<UInt32(3600) {
            // Calm first half-hour, a run in the second.
            let running = t >= 1800
            seconds.append(WhoopSample(unix: hour + t, bpm: running ? 150 : 55,
                                       intervals: running ? [] : [t % 2 == 0 ? 1080 : 1100],
                                       activity: running ? 2 : 0))
        }
        let minutes = WhoopMetrics.minutes(seconds)
        XCTAssertEqual(minutes.count, 60)
        XCTAssertEqual(minutes.first, WhoopMetrics.Minute(start: hour, bpm: 55, still: true))
        XCTAssertEqual(minutes.last?.still, false)

        let hrv = WhoopMetrics.hourlyHRV(seconds)
        XCTAssertEqual(hrv.count, 1)
        XCTAssertLessThan(hrv[0].start, hour + 1800)
        XCTAssertEqual(hrv[0].rmssd, 20, accuracy: 0.001)

        XCTAssertNil(WhoopMetrics.restingHeartRate(minutes))
        let day = (0..<120).map { WhoopMetrics.Minute(start: UInt32($0) * 60, bpm: 50 + Double($0 % 40), still: true) }
        XCTAssertEqual(try XCTUnwrap(WhoopMetrics.restingHeartRate(day)), 54.5, accuracy: 0.001)
    }

    func testHeartbeatRunsChainIntervalsAndBreakOnGaps() {
        let t0: UInt32 = 1_760_000_000
        var seconds = (0..<UInt32(60)).map { WhoopSample(unix: t0 + $0, bpm: 60, intervals: [1000]) }
        // 10 s off-wrist, then another minute.
        seconds += (70..<UInt32(130)).map { WhoopSample(unix: t0 + $0, bpm: 60, intervals: [1000], activity: 0) }
        let runs = WhoopMetrics.heartbeatRuns(seconds)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].count, 60)
        XCTAssertEqual(runs[0].last! - runs[0].first!, 59, accuracy: 0.001)
        XCTAssertEqual(runs[1].first, Double(t0 + 70))
        // A doubled interval runs ahead of the clock and is cut, not trusted.
        let doubled = (0..<UInt32(60)).map { WhoopSample(unix: t0 + $0, bpm: 60, intervals: [1000, 1000]) }
        XCTAssertTrue(WhoopMetrics.heartbeatRuns(doubled).allSatisfy { $0.count < 30 })
    }
}
