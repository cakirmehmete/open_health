import Foundation

/// Oura's nightly breathing rate: a line-by-line twin of tools/ecore_breathing_rate.py,
/// itself a bit-exact port of libecore's `ecore_cpp_calculate_breathing_rate` →
/// `breathing_rate_calculate_averages` (see docs/algorithms/breathing-rate.md). Native
/// ecore code, not a model. Pure and not TORCH-gated so the unit tests can check it
/// against the Python's stored native values in every build.
///
/// Python ints are unbounded; here everything is Int (64-bit) with the same explicit
/// masks, and every float step goes through Double then Float exactly where the Python
/// calls `_f32`, so the float-float IIR rounds identically.
enum EcoreBreathing {
    struct Output: Equatable { let breathingRate: Float; let variability: Float; let heartRate: Float }
    struct Record: Equatable {
        let timeMs: Int64
        let heartRate: Int      // half-bpm (0..255)
        let breathingRate: Int  // 1/8 br/min
        let variability: Int    // 1/8 br/min
        let motion: Int
        let status: Int         // 0 motion-rejected, 1 valid, 2 too few beats
    }

    // MARK: float-float IIR (sleep_preproc_iir_run)

    typealias FF = (Float, Float)
    private static let iirA: [FF] = [
        (9.317317962646484, -1.4588104946255953e-08),
        (-40.191036224365234, 1.9022772903554142e-06),
        (106.20704650878906, 3.1222468805935932e-06),
        (-191.5937042236328, 6.954398941161344e-06),
        (248.65969848632812, -6.640550964220893e-06),
        (-238.12994384765625, 4.5249344111653045e-06),
        (169.5670623779297, 1.37150732371083e-06),
        (-89.11197662353516, -3.131787593702029e-07),
        (33.70725631713867, -1.8264337313667056e-06),
        (-8.711280822753906, -3.1339550332631916e-07),
        (1.3811525106430054, -2.5802775027727876e-08),
        (-0.10160133987665176, -9.471852191467178e-10),
    ]
    private static let iirB: [FF] = [
        (-0.0013682979624718428, -3.7528157664779016e-11),
        (0.003420744091272354, -9.127235078842943e-11),
        (-0.004560992121696472, 1.2169647234383518e-10),
        (0.003420744091272354, -9.127235078842943e-11),
        (-0.0013682979624718428, -3.7528157664779016e-11),
        (0.00022805000480730087, -4.807300824777316e-12),
    ]
    private static let iirC: FF = (0.00022805000480730087, -4.807300824777316e-12)
    private static let sampleMs = 250
    private static let epochMs: Int64 = 30_000

    @inline(__always) private static func f(_ x: Double) -> Float { Float(x) }

    static func ffAdd(_ a: FF, _ b: FF) -> FF {
        let (ah, al) = (Double(a.0), Double(a.1)), (bh, bl) = (Double(b.0), Double(b.1))
        var s1 = f(al + bl)
        let s3 = f(ah + bh)
        let s4 = f(Double(s3) - ah)
        let s5 = f(Double(s3) - Double(s4))
        var s2 = f(bh - Double(s4))
        var s0 = f(ah - Double(s5))
        s0 = f(Double(s2) + Double(s0))
        s1 = f(Double(s1) + Double(s0))
        s0 = f(Double(s3) + Double(s1))
        s2 = f(Double(s0) - Double(s3))
        s1 = f(Double(s1) - Double(s2))
        return (s0, s1)
    }

    static func ffMul(_ a: FF, _ b: FF) -> FF {
        let (ah, al) = (Double(a.0), Double(a.1)), (bh, bl) = (Double(b.0), Double(b.1))
        var s1 = f(al * bh)
        let s4 = f(ah * bh)
        s1 = f(ah * bl + Double(s1))
        var s0 = f(ah * bh - Double(s4))
        s1 = f(Double(s0) + Double(s1))
        s0 = f(Double(s4) + Double(s1))
        let s2 = f(Double(s0) - Double(s4))
        s1 = f(Double(s1) - Double(s2))
        return (s0, s1)
    }

    static func ffMulf(_ a: FF, _ b: Float) -> FF {
        let (ah, al) = (Double(a.0), Double(a.1)), bd = Double(b)
        let s3 = f(ah * bd)
        var s0 = f(ah * bd - Double(s3))
        var s1 = f(al * bd + Double(s0))
        s0 = f(Double(s3) + Double(s1))
        let s2 = f(Double(s0) - Double(s3))
        s1 = f(Double(s1) - Double(s2))
        return (s0, s1)
    }

    /// 12-pole IIR on the 4 Hz RR stream, Q16 output. Keeps only the history it reads.
    struct Iir {
        private var inputs: [Float] = []
        private var outputs: [FF] = []
        mutating func run(_ sample: Int) -> Int {
            let n = inputs.count
            inputs.append(Float(sample & 0xFFFF))
            let zero: FF = (0, 0)
            var value = ffMulf(iirC, inputs[n])
            for i in 0..<6 {
                let k = 2 * i
                var previous = n >= k + 1 ? outputs[n - 1 - k] : zero
                value = ffAdd(value, ffMul(previous, iirA[k]))
                previous = n >= k + 2 ? outputs[n - 2 - k] : zero
                value = ffAdd(value, ffMul(previous, iirA[k + 1]))
                let lag = 2 + 2 * i
                let delayed: Float = n >= lag ? inputs[n - lag] : 0
                value = ffAdd(value, ffMulf(iirB[i], delayed))
            }
            outputs.append(value)
            if n > 64 { inputs.removeFirst(32); outputs.removeFirst(32) }
            let q = Float(Double(value.0) * 65536.0 + 0.5)
            guard q.isFinite, abs(q) < 9.0e18 else { return 0 }
            return Int(q)
        }
    }

    // MARK: libfixmath Q16.16 (rounding and overflow checks on)

    private static let u32 = 0xFFFF_FFFF
    static let fix16Overflow = -0x8000_0000

    static func s32(_ v: Int) -> Int { let m = v & u32; return m & 0x8000_0000 != 0 ? m - 0x1_0000_0000 : m }
    private static func s16(_ v: Int) -> Int { let m = v & 0xFFFF; return m & 0x8000 != 0 ? m - 0x10000 : m }
    private static func s8(_ v: Int) -> Int { let m = v & 0xFF; return m & 0x80 != 0 ? m - 0x100 : m }

    static func fix16Add(_ a: Int, _ b: Int) -> Int {
        let t = s32(a + b)
        if (a ^ b) & 0x8000_0000 == 0 && (t ^ a) & 0x8000_0000 != 0 { return fix16Overflow }
        return t
    }

    static func fix16Sub(_ a: Int, _ b: Int) -> Int {
        let d = s32(a - b)
        if (a ^ b) & 0x8000_0000 != 0 && (d ^ a) & 0x8000_0000 != 0 { return fix16Overflow }
        return d
    }

    static func fix16Mul(_ a: Int, _ b: Int) -> Int {
        var p = a * b                       // |a|,|b| < 2^31: fits in Int64
        let upper = p >> 47
        if p < 0 {
            if upper != -1 { return fix16Overflow }
            p -= 1
        } else if upper != 0 { return fix16Overflow }
        return s32((p >> 16) + ((p >> 15) & 1))
    }

    private static func clz32(_ v: Int) -> Int { let m = UInt32(truncatingIfNeeded: v); return m.leadingZeroBitCount }

    static func fix16Div(_ a: Int, _ b: Int) -> Int {
        if b == 0 { return fix16Overflow }
        var remainder = (a < 0 ? -a : a) & u32
        var divider = (b < 0 ? -b : b) & u32
        var quotient = 0
        var bitPos = 17
        if divider & 0xFFF0_0000 != 0 {
            let shiftedDiv = (divider >> 17) + 1
            quotient = remainder / shiftedDiv
            remainder = (remainder - ((quotient * divider) >> 17)) & u32
        }
        while divider & 0xF == 0 && bitPos >= 4 { divider >>= 4; bitPos -= 4 }
        while remainder != 0 && bitPos >= 0 {
            let shift = min(clz32(remainder), bitPos)
            remainder = (remainder << shift) & u32
            bitPos -= shift
            let div = remainder / divider
            remainder %= divider
            quotient = (quotient + (div << bitPos)) & u32
            if div & ~(u32 >> bitPos) & u32 != 0 { return fix16Overflow }
            remainder = (remainder << 1) & u32
            bitPos -= 1
        }
        var result = ((quotient + 1) & u32) >> 1
        if (a < 0) != (b < 0) { result = -result }
        return s32(result)
    }

    static func fix16Sqrt(_ value: Int) -> Int {
        let negative = value < 0
        var num = (negative ? -value : value) & u32
        var result = 0
        var bit = num & 0xFFF0_0000 != 0 ? 1 << 30 : 1 << 18
        while bit > num { bit >>= 2 }
        for n in 0..<2 {
            while bit != 0 {
                if num >= result + bit {
                    num -= result + bit
                    result = (result >> 1) + bit
                } else {
                    result >>= 1
                }
                bit >>= 2
            }
            if n == 0 {
                if num > 65535 {
                    num -= result
                    num = ((num << 16) - 0x8000) & u32
                    result = ((result << 16) + 0x8000) & u32
                } else {
                    num = (num << 16) & u32
                    result = (result << 16) & u32
                }
                bit = 1 << 14
            }
        }
        if num > result { result += 1 }
        return s32(negative ? -result : result)
    }

    /// Q16 → nearest int, halves away from zero.
    private static func roundQ16(_ v: Int) -> Int {
        v < 0 ? -(((0x8000 - v) & u32) >> 16) : ((v + 0x8000) & u32) >> 16
    }

    // MARK: breathing_rate_calculate_averages state machine

    private static let ibiRing = 256, peakRing = 64, slotCount = 4, motionRing = 16
    static let maxRecords = 1800
    private static let recordInvalid = 2

    private struct Slot { var ibiStart = 0, ibiEnd = 0, peakStart = 0, peakEnd = 0 }

    private struct State {
        var slots = [Slot](repeating: Slot(), count: slotCount)
        var slot = 0
        var ibiRingBuf = [Int](repeating: 0, count: ibiRing)
        var peakInterval = [Int](repeating: 0, count: peakRing)
        var peakAmplitude = [Int](repeating: 0, count: peakRing)
        var motion = [Int](repeating: 0, count: motionRing)
        var motionPos = 0
        var variabilityHistory = [0, 0, 0, 0]
        var variabilityPos = 0
        var epochTime: Int64
        var epochCounter = -1
        var scanFrom = 0
        var previousValue = 0x7FFF
        var armed = false
        var sampleCounter = 0
        var lastPeakSample = 0
        var rsPrev = 0, rsTime = 0, rsNext = 0
        var iir = Iir()
        var records: [Record] = []

        init(bedtime: Int64) { epochTime = bedtime }

        static func mod(_ x: Int, _ m: Int) -> Int { ((x % m) + m) % m }

        mutating func start() {
            advanceSlot()
            motionPos = (motionPos + 1) % motionRing
            motion[motionPos] = 0
            epochCounter += 1
        }

        mutating func advanceSlot() {
            let previous = slots[slot]
            slot = (slot + 1) % slotCount
            slots[slot].ibiStart = previous.ibiEnd; slots[slot].ibiEnd = previous.ibiEnd
            slots[slot].peakStart = previous.peakEnd; slots[slot].peakEnd = previous.peakEnd
        }

        mutating func resample(_ rr: Int) {
            if rsPrev != 0 {
                let end = rsTime + rr
                if rsNext < end {
                    var offset = rsNext - rsTime
                    let numerator = (rr >> 1) | ((rr - rsPrev) * 0x8000)
                    var slope = abs(numerator) / rr
                    if numerator < 0 { slope = -slope }
                    while rsNext < end {
                        let product = offset * slope
                        let delta = product > 0 ? (product + 0x4000) >> 15 : -((0x4000 - product) >> 15)
                        onSample(rsPrev + delta)
                        rsNext += EcoreBreathing.sampleMs
                        offset += EcoreBreathing.sampleMs
                    }
                }
                rsTime = end
            }
            rsPrev = rr
        }

        mutating func onSample(_ sample: Int) {
            let filtered = iir.run(sample)
            let value = filtered < 0 ? -((-filtered) >> 16) : filtered >> 16
            if value < previousValue {
                if armed {
                    let write = slots[slot].peakEnd
                    let following = (write + 1) % peakRing
                    if following != slots[(slot + 1) % slotCount].peakStart {
                        let previous = previousValue
                        let amplitude: Int
                        if ((previous - 0xFE) & 0xFFFF) > 0xFE00 {
                            amplitude = previous / 2      // truncates toward zero, like int(x / 2)
                        } else {
                            amplitude = previous + 0x101 >= 0 ? 0x7F : -0x80
                        }
                        slots[slot].peakEnd = following
                        peakInterval[write] = min(0xFF, sampleCounter - lastPeakSample)
                        peakAmplitude[write] = EcoreBreathing.s8(amplitude)
                        lastPeakSample = sampleCounter
                    }
                }
                armed = false
            }
            if previousValue < value { armed = true }
            previousValue = EcoreBreathing.s16(value)
            sampleCounter += 1
        }

        func slotOrder() -> [Slot] { (0..<slotCount).map { slots[(slot + 1 + $0) % slotCount] } }

        func heartRateQ16() -> Int {
            var total = 0, count = 0
            for s in slotOrder() {
                var i = s.ibiStart
                while i != s.ibiEnd { total += ibiRingBuf[i]; count += 1; i = (i + 1) % ibiRing }
            }
            count &= 0xFFFF
            var averageQ10 = 0xB0800
            if count != 0 {
                let scaled = (total * 0x400 + (count >> 1)) & EcoreBreathing.u32
                if scaled >= count { averageQ10 = scaled / count }
            }
            let beats = fix16Div(0x7530_0000, s32((averageQ10 * 0x40 + 0x8000) & 0xFFFF_0000))
            var bpm = fix16Mul(beats, 0x20000)
            if bpm < 0x230001 { bpm = 0x230000 }
            return bpm
        }

        func acceptedIntervals() -> [Int] {
            var accepted: [Int] = [], cumulative = 0
            for s in slotOrder() {
                var previous = s.peakStart
                var current = (previous + 1) % peakRing
                while current != s.peakEnd {
                    cumulative += peakInterval[previous]
                    if cumulative > 0x28 && peakAmplitude[previous] > 0
                        && peakAmplitude[current] > 0 && peakInterval[current] > 8 {
                        accepted.append(peakInterval[current])
                    }
                    previous = current
                    current = (current + 1) % peakRing
                }
            }
            return accepted
        }

        func breathing(_ samplesThisEpoch: Int) -> (Int, Int) {
            if samplesThisEpoch < 0x29 { return (0x6A, 0x2A) }
            let intervals = acceptedIntervals()
            let u32 = EcoreBreathing.u32
            let total = intervals.reduce(0, +) & u32
            let count = intervals.count
            if count == 0 || total == 0 { return (0x6A, 0x2A) }
            let scaled = ((total & 0xFFFF_FFFE) + count * 0xF000) & u32
            if total > scaled { return (0x6A, 0x2A) }
            let rateX256 = scaled / total
            let mean = fix16Div(s32(rateX256 << 16), 0x100_0000)
            var accumulator = 0, used = 0
            for interval in intervals {
                let deviation = fix16Sub(fix16Div(0xF0_0000, interval << 16), mean)
                accumulator = fix16Add(accumulator, fix16Mul(deviation, deviation))
                used += 1
            }
            let variance = used > 1 && accumulator > 0 ? fix16Div(accumulator, s32(used << 16)) : 0
            var variability = EcoreBreathing.roundQ16(fix16Mul(fix16Sqrt(variance), 0x80000))
            variability = max(0, min(0xFF, variability))
            return (((rateX256 + 0x10) >> 5) & 0xFF, variability)
        }

        func motionStatus() -> Int {
            let m = motion, w = motionPos
            if epochCounter < 10 {
                let recent = m[State.mod(w - 3, 16)] + m[State.mod(w - 2, 16)] + m[State.mod(w - 4, 16)] + m[State.mod(w - 5, 16)]
                return min(0xFF, recent) >= 7 ? 0 : 1
            }
            var busy = 0
            for k in 0..<12 {
                let window = m[State.mod(w - k, 16)] + m[State.mod(w - k - 1, 16)]
                    + m[State.mod(w - k - 2, 16)] + m[State.mod(w - k - 3, 16)]
                if min(0xFF, window) > 2 { busy += 1 }
            }
            return busy > 3 && variabilityHistory.contains(where: { $0 > 0x1B }) ? 0 : 1
        }

        mutating func epoch(_ ibi: [Int], _ ts: [Int64], _ motionSeconds: Int) {
            var readPos = slots[slot].ibiStart
            motion[motionPos] = motionSeconds & 0xFF
            var seen = 0
            let oldestStart = slots[(slot + 1) % slotCount].ibiStart
            let lower = epochTime - EcoreBreathing.epochMs
            var skip = scanFrom
            let windowOpen = lower >= 0       // native u64 compare: below zero nothing counts
            if windowOpen {
                while skip < ts.count && ts[skip] < lower { skip += 1 }
                scanFrom = skip
            }
            var index = skip
            while index < ibi.count {
                let rr = ibi[index], t = ts[index]
                if epochTime < t { break }
                if windowOpen && lower <= t && rr < 2000 {
                    let following = (slots[slot].ibiEnd + 1) % ibiRing
                    if following != oldestStart {
                        ibiRingBuf[slots[slot].ibiEnd] = rr
                        slots[slot].ibiEnd = following
                    }
                    seen += 1
                }
                index += 1
            }
            if seen == 0 { motion[motionPos] = 0 }

            if epochCounter != 0 {
                var heartRate = min(0xFF, EcoreBreathing.roundQ16(fix16Mul(heartRateQ16(), 0x20000)))
                let samplesBefore = sampleCounter
                while readPos != slots[slot].ibiEnd {
                    resample(ibiRingBuf[readPos])
                    readPos = (readPos + 1) % ibiRing
                }
                var (breathingRate, variability) = breathing(sampleCounter - samplesBefore)
                let s = slots[slot]
                let status: Int, motionSum: Int
                if s.ibiEnd == s.ibiStart || s.ibiEnd == (s.ibiStart + 1) % ibiRing {
                    status = recordInvalid; motionSum = 0xF
                    variability = 0x10; breathingRate = 0x50; heartRate = 0xAA
                } else {
                    status = motionStatus()
                    let w = motionPos
                    motionSum = min(0xFF, (0..<4).reduce(0) { $0 + motion[State.mod(w - $1, 16)] })
                    variabilityHistory[variabilityPos] = variability
                    variabilityPos = (variabilityPos + 1) % 4
                    heartRate = max(0, heartRate)
                }
                if records.count < maxRecords {
                    records.append(Record(timeMs: epochTime - EcoreBreathing.epochMs, heartRate: heartRate,
                                          breathingRate: breathingRate, variability: variability,
                                          motion: motionSum, status: status))
                }
            }
            advanceSlot()
            motionPos = (motionPos + 1) % motionRing
            motion[motionPos] = 0
            epochTime += EcoreBreathing.epochMs
            epochCounter += 1
        }
    }

    /// Per-epoch records exactly as libecore stores them (one per epoch after the first).
    static func epochRecords(bedtimeStartMs: Int64, ibi: [Int], timestampsMs: [Int64], motionSeconds: [Int]) -> [Record] {
        precondition(ibi.count == timestampsMs.count, "ibi and timestamps must have equal length")
        var state = State(bedtime: bedtimeStartMs)
        state.start()
        for m in motionSeconds { state.epoch(ibi, timestampsMs, m) }
        return state.records
    }

    /// The night average. `motionSeconds` has one value per 30 s epoch; its length is the
    /// epoch count. Nights of 360 epochs or fewer return zeros.
    static func calculate(bedtimeStartMs: Int64, ibi: [Int], timestampsMs: [Int64], motionSeconds: [Int]) -> Output {
        let epochCount = motionSeconds.count
        let zero = Output(breathingRate: 0, variability: 0, heartRate: 0)
        let records = epochRecords(bedtimeStartMs: bedtimeStartMs, ibi: ibi, timestampsMs: timestampsMs,
                                   motionSeconds: motionSeconds)
        var first = 0
        let cutoff = UInt64(bitPattern: bedtimeStartMs - epochMs)
        if let i = records.firstIndex(where: { cutoff <= UInt64(bitPattern: $0.timeMs) }) { first = i }
        if epochCount <= 360 { return zero }
        var start: Int, end: Int
        if epochCount <= 600 {
            start = epochCount / 2 - 180; end = epochCount / 2 + 180
        } else {
            start = first + 120; end = epochCount + first - 120
        }
        end = min(end, maxRecords)
        if end <= start { return zero }
        let window = records[min(start, records.count)..<min(end, records.count)]
        let valid = window.filter { $0.status != recordInvalid }
        if valid.isEmpty { return zero }
        let count = valid.count, half = count >> 1
        let hr = ((valid.reduce(0) { $0 + $1.heartRate } * 4 + half) / count) & 0xFFFF
        let br = ((valid.reduce(0) { $0 + $1.breathingRate } + half) / count) & 0xFF
        let brv = ((valid.reduce(0) { $0 + $1.variability } + half) / count) & 0xFF
        return Output(breathingRate: Float(Double(br) / 8), variability: Float(Double(brv) / 8),
                      heartRate: Float(Double(hr) / 8))
    }

    /// Seconds of motion per epoch from 0x47 events, in the beats' window (t − 30 s, t].
    /// Same (unconfirmed) alignment as the Python CLI's `_motion_per_epoch`.
    static func motionPerEpoch(bedtimeStartMs: Int64, epochCount: Int, events: [(Int64, Int)]) -> [Int] {
        var motion = [Int](repeating: 0, count: max(0, epochCount))
        for (t, seconds) in events {
            let d = t - bedtimeStartMs
            let epoch = Int(d >= 0 ? (d + epochMs - 1) / epochMs : -((-d) / epochMs))   // ceil
            if epoch >= 0 && epoch < motion.count { motion[epoch] = max(0, min(0xFF, motion[epoch] + seconds)) }
        }
        return motion
    }
}
