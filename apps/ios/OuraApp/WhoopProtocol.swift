import Foundation

/// WHOOP 5.0 / MG wire protocol (the `fd4b` "Maverick" service): framing, the few
/// commands we send, and the records we read back. Pure bytes, no CoreBluetooth,
/// so all of it is unit tested.
///
/// Protocol facts come from public reverse engineering; the code is written here:
/// - Rudra5417/whoop5-protocol (MIT): the 8-byte envelope, CRC16-Modbus + CRC32,
///   the four-byte body padding, CLIENT_HELLO.
/// - eugenehp/whoop-rs (Apache-2.0): command numbers, the R18 record layout,
///   offload metadata and the store-then-acknowledge rule.
/// - Sophonbot0/whoop-vault (MIT), rusheelraj.com/blog/whoop, judes.club: the
///   history drain verified on real straps, including one whose membership lapsed.
enum WhoopWire {
    static let service = "fd4b0001-cce1-4033-93ce-002d5875f58a"
    static let commandChar = "fd4b0002-cce1-4033-93ce-002d5875f58a"
    /// Command responses, events and data. `…0007` (Memfault crash logs) is not needed.
    static let notifyChars = ["fd4b0003-cce1-4033-93ce-002d5875f58a",
                              "fd4b0004-cce1-4033-93ce-002d5875f58a",
                              "fd4b0005-cce1-4033-93ce-002d5875f58a"]

    /// `GET_HELLO` (145), sequence 1, revision 1: the fixed opener every 5.0 client
    /// sends once subscriptions are up. Equal to `command(145, seq: 1, body: [1])`.
    static let clientHello: [UInt8] = [0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
                                       0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D]

    // MARK: Checksums

    /// CRC16-Modbus over the first six header bytes.
    static func crc16Modbus<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    /// zlib CRC32 over the payload.
    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: Building

    /// `[0x23 COMMAND][seq][cmd][body…]`, zero-padded to a multiple of four (the
    /// strap rejects unaligned bodies), then the envelope.
    static func command(_ command: UInt8, seq: UInt8, body: [UInt8] = []) -> [UInt8] {
        var payload: [UInt8] = [0x23, seq, command] + body
        while payload.count % 4 != 0 { payload.append(0) }
        return frame(payload: payload)
    }

    /// `AA 01 len16 00 01 crc16` + payload + crc32. `len` counts the CRC32 trailer.
    static func frame(payload: [UInt8]) -> [UInt8] {
        var header: [UInt8] = [0xAA, 0x01] + le16(UInt16(payload.count + 4)) + [0x00, 0x01]
        header += le16(crc16Modbus(header))
        return header + payload + le32(crc32(payload))
    }

    // MARK: Reading

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
    static func u16(_ b: [UInt8], _ i: Int) -> UInt16? {
        i >= 0 && i + 1 < b.count ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : nil
    }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32? {
        guard let lo = u16(b, i), let hi = u16(b, i + 2) else { return nil }
        return UInt32(lo) | UInt32(hi) << 16
    }
    static func f32(_ b: [UInt8], _ i: Int) -> Float? { u32(b, i).map(Float.init(bitPattern:)) }

    /// Splits one notify characteristic's byte stream into whole, checksum-valid
    /// frames. Large records (optical, IMU) span several notifications.
    struct Reassembler {
        private var buffer: [UInt8] = []
        private(set) var dropped = 0

        mutating func append(_ data: Data) -> [[UInt8]] {
            buffer.append(contentsOf: data)
            var frames: [[UInt8]] = []
            while buffer.count >= 8 {
                guard buffer[0] == 0xAA else { buffer.removeFirst(); dropped += 1; continue }
                let total = Int(u16(buffer, 2) ?? 0) + 8
                guard total >= 13, total <= 16_384,
                      crc16Modbus(buffer[0..<6]) == u16(buffer, 6) else {
                    buffer.removeFirst(); dropped += 1; continue
                }
                guard buffer.count >= total else { break }
                let candidate = Array(buffer[0..<total])
                buffer.removeFirst(total)
                if crc32(candidate[8..<(total - 4)]) == u32(candidate, total - 4) {
                    frames.append(candidate)
                } else {
                    dropped += 1
                }
            }
            return frames
        }
    }
}

/// The commands this app sends. Nothing that erases, reflashes or reconfigures.
enum WhoopCommand: UInt8 {
    case setClockLegacy = 10
    case abortHistory = 20
    case sendHistory = 22
    case historyResult = 23
    case getHello = 145
    case setClock = 146

    /// `SET_CLOCK` (146): revision 1, unix seconds, ticks of 1/32768 s.
    static func clockBody(_ date: Date) -> [UInt8] {
        let t = date.timeIntervalSince1970
        let ticks = UInt16(min(32767, (t - t.rounded(.down)) * 32768))
        return [0x01] + WhoopWire.le32(UInt32(t)) + WhoopWire.le16(ticks)
    }

    /// The older clock command (10) that some 5.0 firmware still answers.
    static func legacyClockBody(_ date: Date) -> [UInt8] {
        WhoopWire.le32(UInt32(date.timeIntervalSince1970)) + [0, 0, 0, 0]
    }
}

/// Packet types (the first payload byte, frame offset 8).
enum WhoopPacket {
    static let commandResponse: UInt8 = 0x24
    static let commandResponse5: UInt8 = 0x26
    static let realtime: UInt8 = 0x28
    static let historical: UInt8 = 0x2F
    static let event: UInt8 = 0x30
    static let metadata: UInt8 = 0x31
    static let consoleLog: UInt8 = 0x32
    static let historicalIMU: UInt8 = 0x34
    static let metadata5: UInt8 = 0x38

    /// Traffic that proves an offload is still moving (re-arms the drain watchdog).
    static func isOffload(_ type: UInt8) -> Bool {
        [historical, event, metadata, consoleLog, historicalIMU, metadata5].contains(type)
    }
}

/// A command response: `[type][seq][cmd][origin seq][result][body…]`.
struct WhoopResponse {
    enum Result: UInt8 { case failure = 0, success = 1, pending = 2, unsupported = 3 }
    let command: UInt8
    let originSeq: UInt8
    let resultByte: UInt8
    let body: [UInt8]
    var result: Result? { Result(rawValue: resultByte) }

    init?(frame f: [UInt8]) {
        guard f.count >= 17, f[8] == WhoopPacket.commandResponse || f[8] == WhoopPacket.commandResponse5 else { return nil }
        command = f[10]; originSeq = f[11]; resultByte = f[12]
        body = 13 < f.count - 4 ? Array(f[13..<(f.count - 4)]) : []
    }

    /// Firmware string from a final `GET_HELLO` reply (revision 1 or 3).
    var helloFirmware: String? {
        guard command == WhoopCommand.getHello.rawValue, result == .success,
              let revision = body.first, revision == 1 || revision == 3,
              body.count >= 98, let suffix = WhoopWire.u32(body, 94) else { return nil }
        return "\(body[91]).\(body[92]).\(body[93]).\(suffix)"
    }
}

/// Offload control: one START, then an END per chunk (each must be acknowledged
/// with its 8-byte block echoed verbatim), then COMPLETE for the attempt.
enum WhoopMeta: Equatable {
    case start
    case end(block: [UInt8]?)
    case complete

    init?(frame f: [UInt8]) {
        guard f.count >= 15, f[8] == WhoopPacket.metadata || f[8] == WhoopPacket.metadata5 else { return nil }
        switch f[10] {
        case 1: self = .start
        case 2: self = .end(block: 29 <= f.count - 4 ? Array(f[21..<29]) : nil)
        case 3: self = .complete
        default: return nil
        }
    }

    /// `HISTORICAL_DATA_RESULT` body: success + the block. Only after the chunk is stored.
    static func ackBody(_ block: [UInt8]) -> [UInt8] { [0x01] + block }
}

/// One second of history: WHOOP 5 record layout R18 (124-byte frame).
struct WhoopSample: Equatable {
    var unix: UInt32
    var index: UInt32
    var bpm: UInt8
    /// Up to four R-R intervals in milliseconds; only the first `rrCount` are set.
    var rr: (UInt16, UInt16, UInt16, UInt16)
    var rrCount: UInt8
    /// 0 still, 1 walk, 2 run, 0xFF unknown.
    var activity: UInt8
    var quality: UInt8
    /// Hundredths of a °C, 0 when absent.
    var skinTempCenti: UInt16
    var steps: UInt16

    static let frameLength = 124
    static let storedLength = 28

    static func == (a: WhoopSample, b: WhoopSample) -> Bool { a.encoded() == b.encoded() }

    var intervals: [Double] {
        [rr.0, rr.1, rr.2, rr.3].prefix(Int(rrCount)).map(Double.init)
    }

    init(unix: UInt32, index: UInt32 = 0, bpm: UInt8, intervals: [UInt16] = [], activity: UInt8 = 0xFF,
         quality: UInt8 = 0, skinTempCenti: UInt16 = 0, steps: UInt16 = 0) {
        let r = intervals.prefix(4) + Array(repeating: 0, count: max(0, 4 - intervals.count))
        self.unix = unix; self.index = index; self.bpm = bpm
        self.rr = (r[0], r[1], r[2], r[3]); self.rrCount = UInt8(min(4, intervals.count))
        self.activity = activity; self.quality = quality
        self.skinTempCenti = skinTempCenti; self.steps = steps
    }

    /// Decode a history frame. Nil for any other layout (optical, IMU, ECG…),
    /// which still count toward the chunk but aren't used.
    init?(r18 f: [UInt8]) {
        guard f.count == Self.frameLength, f[8] == WhoopPacket.historical, f[9] == 18,
              let index = WhoopWire.u32(f, 11), let unix = WhoopWire.u32(f, 15) else { return nil }
        var intervals: [UInt16] = []
        for i in 0..<min(4, Int(f[23])) {
            // Ticks of 1/1024 s, rounded to whole milliseconds.
            if let ticks = WhoopWire.u16(f, 24 + i * 2), ticks != 0 {
                intervals.append(UInt16((UInt32(ticks) * 1000 + 512) / 1024))
            }
        }
        let temp = WhoopWire.u16(f, 73) ?? 0
        self.init(unix: unix, index: index, bpm: f[22], intervals: intervals,
                  activity: f[63] <= 2 ? f[63] : 0xFF, quality: f[36],
                  skinTempCenti: (500...4500).contains(temp) ? temp : 0,
                  steps: WhoopWire.u16(f, 57) ?? 0)
    }

    // Fixed 28-byte storage record, little-endian.
    func encoded() -> [UInt8] {
        WhoopWire.le32(unix) + WhoopWire.le32(index) + [bpm, rrCount, activity, quality]
            + WhoopWire.le16(rr.0) + WhoopWire.le16(rr.1) + WhoopWire.le16(rr.2) + WhoopWire.le16(rr.3)
            + WhoopWire.le16(skinTempCenti) + WhoopWire.le16(steps) + [0, 0, 0, 0]
    }

    init?(stored b: [UInt8], at o: Int) {
        guard o + Self.storedLength <= b.count, let unix = WhoopWire.u32(b, o),
              let index = WhoopWire.u32(b, o + 4) else { return nil }
        let rrs = (0..<4).map { WhoopWire.u16(b, o + 12 + $0 * 2) ?? 0 }
        self.init(unix: unix, index: index, bpm: b[o + 8], intervals: Array(rrs.prefix(Int(min(4, b[o + 9])))),
                  activity: b[o + 10], quality: b[o + 11],
                  skinTempCenti: WhoopWire.u16(b, o + 20) ?? 0, steps: WhoopWire.u16(b, o + 22) ?? 0)
    }
}

/// The live ~1 Hz heart-rate packet (realtime type 0x28, record type 2). Shown on
/// the status card only; Health is fed from history, which covers the same seconds.
struct WhoopLiveBeat {
    let bpm: Int
    init?(frame f: [UInt8]) {
        guard f.count >= 28, f[8] == WhoopPacket.realtime, f[9] == 0x02, f[16] > 0 else { return nil }
        bpm = Int(f[16])
    }
}

/// Health metrics from stored seconds. Pure, so they're tested without HealthKit.
enum WhoopMetrics {
    struct Minute: Equatable { let start: UInt32; let bpm: Double; let still: Bool }
    struct HRV: Equatable { let start: UInt32; let end: UInt32; let sdnn: Double; let rmssd: Double; let beats: Int }

    /// Mean heart rate per clock minute, for minutes with at least 10 plausible seconds.
    static func minutes(_ samples: [WhoopSample]) -> [Minute] {
        var groups: [UInt32: (sum: Double, n: Int, moving: Bool)] = [:]
        for s in samples where (30...230).contains(s.bpm) {
            let m = s.unix - s.unix % 60
            var g = groups[m] ?? (0, 0, false)
            g.sum += Double(s.bpm); g.n += 1
            if s.activity == 1 || s.activity == 2 { g.moving = true }
            groups[m] = g
        }
        return groups.filter { $0.value.n >= 10 }
            .map { Minute(start: $0.key, bpm: $0.value.sum / Double($0.value.n), still: !$0.value.moving) }
            .sorted { $0.start < $1.start }
    }

    /// SDNN and RMSSD of a beat series after dropping implausible intervals and
    /// ectopic jumps (>20 % from the previous accepted beat). Nil under 100 clean beats.
    static func hrv(_ intervals: [Double]) -> (sdnn: Double, rmssd: Double, beats: Int)? {
        var clean: [Double] = []
        var diffs: [Double] = []
        var previous: Double?
        for rr in intervals where (300...2000).contains(rr) {
            if let p = previous {
                guard abs(rr - p) / p <= 0.2 else { previous = nil; continue }
                diffs.append(rr - p)
            }
            clean.append(rr)
            previous = rr
        }
        guard clean.count >= 100, !diffs.isEmpty else { return nil }
        let mean = clean.reduce(0, +) / Double(clean.count)
        let sdnn = (clean.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(clean.count - 1)).squareRoot()
        let rmssd = (diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)).squareRoot()
        return (sdnn, rmssd, clean.count)
    }

    /// One HRV reading per clock hour: of its twelve 5-minute windows, the still one
    /// with the lowest heart rate (closest to a resting measurement, like a watch's
    /// background reading). Samples must cover whole hours from `hourStart`.
    static func hourlyHRV(_ samples: [WhoopSample]) -> [HRV] {
        var windows: [UInt32: [WhoopSample]] = [:]
        for s in samples { windows[s.unix - s.unix % 300, default: []].append(s) }
        var best: [UInt32: (hrv: HRV, bpm: Double)] = [:]
        for (start, seconds) in windows {
            let moving = seconds.filter { $0.activity == 1 || $0.activity == 2 }.count
            guard seconds.count >= 240, moving * 10 <= seconds.count,
                  let r = hrv(seconds.flatMap(\.intervals)) else { continue }
            let rates = seconds.filter { $0.bpm > 0 }.map { Double($0.bpm) }
            let bpm = rates.isEmpty ? 999 : rates.reduce(0, +) / Double(rates.count)
            let hour = start - start % 3600
            let reading = HRV(start: start, end: start + 300, sdnn: r.sdnn, rmssd: r.rmssd, beats: r.beats)
            if best[hour].map({ bpm < $0.bpm }) ?? true { best[hour] = (reading, bpm) }
        }
        return best.values.map(\.hrv).sorted { $0.start < $1.start }
    }

    /// Beat times (unix seconds) rebuilt from the R-R intervals, as runs for Health's
    /// heartbeat series. Each run starts at its record's second and chains the
    /// intervals; it breaks where a second has no intervals for over 2.5 s, or where
    /// the chained time drifts more than 2.5 s from the record clock (a missed or
    /// repeated interval). Runs are capped at 5 minutes and need 30 beats.
    static func heartbeatRuns(_ samples: [WhoopSample]) -> [[Double]] {
        var runs: [[Double]] = []
        var run: [Double] = []
        func flush() { if run.count >= 30 { runs.append(run) }; run = [] }
        for s in samples.sorted(by: { $0.unix < $1.unix }) {
            let clock = Double(s.unix)
            if let last = run.last, s.rrCount == 0, clock - last > 2.5 { flush() }
            for rr in s.intervals where (300...2000).contains(rr) {
                guard let last = run.last else { run = [clock]; continue }
                let t = last + rr / 1000
                if abs(t - clock) > 2.5 || t - run[0] > 300 { flush(); run = [clock]; continue }
                run.append(t)
            }
        }
        flush()
        return runs
    }

    /// Resting heart rate for a day: the mean of its lowest tenth of still minutes.
    /// Nil with under 60 still minutes (the strap wasn't worn enough).
    static func restingHeartRate(_ minutes: [Minute]) -> Double? {
        let still = minutes.filter(\.still).map(\.bpm).sorted()
        guard still.count >= 60 else { return nil }
        let lowest = still.prefix(max(30, still.count / 10))
        return lowest.reduce(0, +) / Double(lowest.count)
    }
}
