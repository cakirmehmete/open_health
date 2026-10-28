from __future__ import annotations

import math
import struct
from dataclasses import dataclass
from typing import Sequence


_IIR_A = (
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
)

_IIR_B = (
    (-0.0013682979624718428, -3.7528157664779016e-11),
    (0.003420744091272354, -9.127235078842943e-11),
    (-0.004560992121696472, 1.2169647234383518e-10),
    (0.003420744091272354, -9.127235078842943e-11),
    (-0.0013682979624718428, -3.7528157664779016e-11),
    (0.00022805000480730087, -4.807300824777316e-12),
)

_IIR_C = (0.00022805000480730087, -4.807300824777316e-12)
_SAMPLE_MS = 250       # rr_resample_init(4): 4 Hz
_EPOCH_MS = 30_000


@dataclass(frozen=True)
class BreathingRateOutput:
    avg_breathing_rate: float
    avg_breathing_rate_variability: float
    avg_heart_rate: float


def _f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


def _ff_add(a: tuple[float, float], b: tuple[float, float]) -> tuple[float, float]:
    a_hi, a_lo = a
    b_hi, b_lo = b
    s1 = _f32(a_lo + b_lo)
    s3 = _f32(a_hi + b_hi)
    s4 = _f32(s3 - a_hi)
    s5 = _f32(s3 - s4)
    s2 = _f32(b_hi - s4)
    s0 = _f32(a_hi - s5)
    s0 = _f32(s2 + s0)
    s1 = _f32(s1 + s0)
    s0 = _f32(s3 + s1)
    s2 = _f32(s0 - s3)
    s1 = _f32(s1 - s2)
    return s0, s1


def _ff_mul(a: tuple[float, float], b: tuple[float, float]) -> tuple[float, float]:
    a_hi, a_lo = a
    b_hi, b_lo = b
    s1 = _f32(a_lo * b_hi)
    s4 = _f32(a_hi * b_hi)
    s1 = _f32(a_hi * b_lo + s1)
    s0 = _f32(a_hi * b_hi - s4)
    s1 = _f32(s0 + s1)
    s0 = _f32(s4 + s1)
    s2 = _f32(s0 - s4)
    s1 = _f32(s1 - s2)
    return s0, s1


def _ff_mulf(a: tuple[float, float], b: float) -> tuple[float, float]:
    a_hi, a_lo = a
    s3 = _f32(a_hi * b)
    s0 = _f32(a_hi * b - s3)
    s1 = _f32(a_lo * b + s0)
    s0 = _f32(s3 + s1)
    s2 = _f32(s0 - s3)
    s1 = _f32(s1 - s2)
    return s0, s1


class _Iir:
    """sleep_preproc_iir_run: 12-pole float-float IIR on the 4 Hz RR stream, Q16 output."""

    def __init__(self) -> None:
        self.inputs: list[float] = []
        self.outputs: list[tuple[float, float]] = []

    def run(self, sample: int) -> int:
        n = len(self.inputs)
        self.inputs.append(float(sample & 0xFFFF))
        zero = (0.0, 0.0)
        value = _ff_mulf(_IIR_C, self.inputs[n])
        for i in range(6):
            k = 2 * i
            previous = self.outputs[n - 1 - k] if n >= k + 1 else zero
            value = _ff_add(value, _ff_mul(previous, _IIR_A[k]))
            previous = self.outputs[n - 2 - k] if n >= k + 2 else zero
            value = _ff_add(value, _ff_mul(previous, _IIR_A[k + 1]))
            lag = 2 + 2 * i
            delayed = self.inputs[n - lag] if n >= lag else 0.0
            value = _ff_add(value, _ff_mulf(_IIR_B[i], delayed))
        self.outputs.append(value)
        # Only the last 12 outputs / 13 inputs are ever read; keep memory flat on long nights.
        if n > 64:
            del self.inputs[:32]
            del self.outputs[:32]
        return int(_f32(value[0] * 65536.0 + 0.5))


def _filter_ibi(samples: Sequence[int]) -> list[int]:
    iir = _Iir()
    return [iir.run(int(sample)) for sample in samples]


# --- libfixmath Q16.16 (as linked into libecore: rounding and overflow checks on) ---

_U32 = 0xFFFFFFFF
_FIX16_OVERFLOW = -0x80000000


def _s32(value: int) -> int:
    value &= _U32
    return value - 0x1_0000_0000 if value & 0x8000_0000 else value


def _fix16_add(a: int, b: int) -> int:
    total = _s32(a + b)
    if not ((a ^ b) & 0x8000_0000) and ((total ^ a) & 0x8000_0000):
        return _FIX16_OVERFLOW
    return total


def _fix16_sub(a: int, b: int) -> int:
    diff = _s32(a - b)
    if ((a ^ b) & 0x8000_0000) and ((diff ^ a) & 0x8000_0000):
        return _FIX16_OVERFLOW
    return diff


def _fix16_mul(a: int, b: int) -> int:
    product = a * b
    upper = product >> 47
    if product < 0:
        if upper != -1:
            return _FIX16_OVERFLOW
        product -= 1
    elif upper != 0:
        return _FIX16_OVERFLOW
    return _s32((product >> 16) + ((product >> 15) & 1))


def _clz32(value: int) -> int:
    return 32 - (value & _U32).bit_length()


def _fix16_div(a: int, b: int) -> int:
    if b == 0:
        return _FIX16_OVERFLOW
    remainder = (-a if a < 0 else a) & _U32
    divider = (-b if b < 0 else b) & _U32
    quotient = 0
    bit_pos = 17

    if divider & 0xFFF00000:
        shifted_div = (divider >> 17) + 1
        quotient = remainder // shifted_div
        remainder = (remainder - ((quotient * divider) >> 17)) & _U32

    while not (divider & 0xF) and bit_pos >= 4:
        divider >>= 4
        bit_pos -= 4

    while remainder and bit_pos >= 0:
        shift = min(_clz32(remainder), bit_pos)
        remainder = (remainder << shift) & _U32
        bit_pos -= shift
        div = remainder // divider
        remainder %= divider
        quotient = (quotient + (div << bit_pos)) & _U32
        if div & ~(_U32 >> bit_pos) & _U32:
            return _FIX16_OVERFLOW
        remainder = (remainder << 1) & _U32
        bit_pos -= 1

    result = ((quotient + 1) & _U32) >> 1
    if (a < 0) != (b < 0):
        result = -result
    return _s32(result)


def _fix16_sqrt(value: int) -> int:
    negative = value < 0
    num = (-value if negative else value) & _U32
    result = 0
    bit = 1 << 30 if num & 0xFFF00000 else 1 << 18
    while bit > num:
        bit >>= 2

    for n in range(2):
        while bit:
            if num >= result + bit:
                num -= result + bit
                result = (result >> 1) + bit
            else:
                result >>= 1
            bit >>= 2
        if n == 0:
            if num > 65535:
                num -= result
                num = ((num << 16) - 0x8000) & _U32
                result = ((result << 16) + 0x8000) & _U32
            else:
                num = (num << 16) & _U32
                result = (result << 16) & _U32
            bit = 1 << 14

    if num > result:
        result += 1
    return _s32(-result if negative else result)


def _round_q16(value: int) -> int:
    """Q16 -> nearest int, halves away from zero (the native `(x + 0x8000) >> 16` pattern)."""
    if value < 0:
        return -(((0x8000 - value) & _U32) >> 16)
    return ((value + 0x8000) & _U32) >> 16


def _s16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def _s8(value: int) -> int:
    value &= 0xFF
    return value - 0x100 if value & 0x80 else value


# --- breathing_rate_calculate_averages state machine ---

_IBI_RING = 256      # IBI ring (u16 values), indexed by the 4 epoch slots
_PEAK_RING = 64      # breathing-peak ring: (interval in samples, amplitude sign byte)
_SLOTS = 4           # epochs of history used for HR and BR
_MOTION_RING = 16
_MAX_RECORDS = 1800
_RECORD_INVALID = 2


@dataclass
class EpochRecord:
    """One 14-byte native record: epoch start time and the per-epoch bytes."""

    time_ms: int
    heart_rate: int          # half-bpm units (0..255)
    breathing_rate: int      # 1/8 breaths per minute
    variability: int         # 1/8 breaths per minute
    motion: int              # sum of the last 4 epochs' motion seconds (0..255)
    status: int              # 0 = motion-rejected, 1 = valid, 2 = too few beats


class _Slot:
    __slots__ = ("ibi_start", "ibi_end", "peak_start", "peak_end")

    def __init__(self) -> None:
        self.ibi_start = 0
        self.ibi_end = 0
        self.peak_start = 0
        self.peak_end = 0


class _BreathingRateState:
    def __init__(self, bedtime_start_ms: int) -> None:
        self.slots = [_Slot() for _ in range(_SLOTS)]
        self.slot = 0
        self.ibi_ring = [0] * _IBI_RING
        self.peak_interval = [0] * _PEAK_RING
        self.peak_amplitude = [0] * _PEAK_RING
        self.motion = [0] * _MOTION_RING
        self.motion_pos = 0
        self.variability_history = [0] * 4
        self.variability_pos = 0
        self.epoch_time = bedtime_start_ms
        self.epoch_counter = -1
        self.scan_from = 0
        # Peak detector (FUN_00201a08)
        self.previous_value = 0x7FFF
        self.armed = False
        self.sample_counter = 0
        self.last_peak_sample = 0
        # Resampler (resample_rr), 4 Hz
        self.rs_prev = 0
        self.rs_time = 0
        self.rs_next = 0
        self.iir = _Iir()
        self.records: list[EpochRecord] = []

    # Equivalent of the init block that runs before the epoch loop.
    def start(self) -> None:
        self._advance_slot()
        self.motion_pos = (self.motion_pos + 1) % _MOTION_RING
        self.motion[self.motion_pos] = 0
        self.epoch_counter += 1

    def _advance_slot(self) -> None:
        previous = self.slots[self.slot]
        self.slot = (self.slot + 1) % _SLOTS
        current = self.slots[self.slot]
        current.ibi_start = current.ibi_end = previous.ibi_end
        current.peak_start = current.peak_end = previous.peak_end

    def _resample(self, rr: int) -> None:
        if self.rs_prev != 0:
            end = self.rs_time + rr
            if self.rs_next < end:
                offset = self.rs_next - self.rs_time
                numerator = (rr >> 1) | ((rr - self.rs_prev) * 0x8000)
                slope = abs(numerator) // rr
                if numerator < 0:
                    slope = -slope
                while self.rs_next < end:
                    product = offset * slope
                    if product > 0:
                        delta = (product + 0x4000) >> 15
                    else:
                        delta = -((0x4000 - product) >> 15)
                    self._on_sample(self.rs_prev + delta)
                    self.rs_next += _SAMPLE_MS
                    offset += _SAMPLE_MS
            self.rs_time = end
        self.rs_prev = rr

    def _on_sample(self, sample: int) -> None:
        filtered = self.iir.run(sample)
        value = -((-filtered) >> 16) if filtered < 0 else filtered >> 16
        if value < self.previous_value:
            if self.armed:
                slot = self.slots[self.slot]
                write = slot.peak_end
                following = (write + 1) % _PEAK_RING
                if following != self.slots[(self.slot + 1) % _SLOTS].peak_start:
                    previous = self.previous_value
                    if ((previous - 0xFE) & 0xFFFF) > 0xFE00:
                        amplitude = int(previous / 2)
                    else:
                        amplitude = 0x7F if previous + 0x101 >= 0 else -0x80
                    slot.peak_end = following
                    self.peak_interval[write] = min(0xFF, self.sample_counter - self.last_peak_sample)
                    self.peak_amplitude[write] = _s8(amplitude)
                    self.last_peak_sample = self.sample_counter
            self.armed = False
        if self.previous_value < value:
            self.armed = True
        self.previous_value = _s16(value)
        self.sample_counter += 1

    def _slot_order(self) -> list[_Slot]:
        return [self.slots[(self.slot + 1 + k) % _SLOTS] for k in range(_SLOTS)]

    def _heart_rate_q16(self) -> int:
        total = 0
        count = 0
        for slot in self._slot_order():
            index = slot.ibi_start
            while index != slot.ibi_end:
                total += self.ibi_ring[index]
                count += 1
                index = (index + 1) % _IBI_RING
        count &= 0xFFFF
        average_q10 = 0xB0800
        if count:
            scaled = (total * 0x400 + (count >> 1)) & _U32
            if scaled >= count:
                average_q10 = scaled // count
        # 0x7530 = 30000: 30 s / mean IBI -> beats per 30 s, then x2 -> per minute.
        beats = _fix16_div(0x75300000, _s32((average_q10 * 0x40 + 0x8000) & 0xFFFF0000))
        bpm = _fix16_mul(beats, 0x20000)
        if bpm < 0x230001:
            bpm = 0x230000
        return bpm

    def _accepted_intervals(self) -> list[int]:
        accepted = []
        cumulative = 0
        for slot in self._slot_order():
            previous = slot.peak_start
            current = (previous + 1) % _PEAK_RING
            while current != slot.peak_end:
                cumulative += self.peak_interval[previous]
                if (cumulative > 0x28 and self.peak_amplitude[previous] > 0
                        and self.peak_amplitude[current] > 0 and self.peak_interval[current] > 8):
                    accepted.append(self.peak_interval[current])
                previous = current
                current = (current + 1) % _PEAK_RING
        return accepted

    def _breathing(self, samples_this_epoch: int) -> tuple[int, int]:
        """Returns (breathing_rate, variability) bytes; 0x6A/0x2A when there is no estimate."""
        if samples_this_epoch < 0x29:
            return 0x6A, 0x2A
        intervals = self._accepted_intervals()
        total = sum(intervals) & _U32
        count = len(intervals)
        if not count or not total:
            return 0x6A, 0x2A
        scaled = ((total & 0xFFFFFFFE) + count * 0xF000) & _U32
        if total > scaled:
            return 0x6A, 0x2A
        rate_x256 = scaled // total
        mean = _fix16_div(_s32(rate_x256 << 16), 0x1000000)

        accumulator = 0
        used = 0
        for interval in intervals:
            deviation = _fix16_sub(_fix16_div(0xF00000, interval << 16), mean)
            accumulator = _fix16_add(accumulator, _fix16_mul(deviation, deviation))
            used += 1
        variance = _fix16_div(accumulator, _s32(used << 16)) if used > 1 and accumulator > 0 else 0
        variability = _round_q16(_fix16_mul(_fix16_sqrt(variance), 0x80000))
        variability = max(0, min(0xFF, variability))
        breathing_rate = ((rate_x256 + 0x10) >> 5) & 0xFF
        return breathing_rate, variability

    def _motion_status(self) -> int:
        m = self.motion
        w = self.motion_pos
        if self.epoch_counter < 10:
            recent = m[(w - 3) % 16] + m[(w - 2) % 16] + m[(w - 4) % 16] + m[(w - 5) % 16]
            return 0 if min(0xFF, recent) >= 7 else 1
        busy_windows = 0
        for k in range(12):
            window = m[(w - k) % 16] + m[(w - k - 1) % 16] + m[(w - k - 2) % 16] + m[(w - k - 3) % 16]
            if min(0xFF, window) > 2:
                busy_windows += 1
        if busy_windows > 3 and any(v > 0x1B for v in self.variability_history):
            return 0
        return 1

    def epoch(self, ibi_values: Sequence[int], ibi_timestamps_ms: Sequence[int], motion_seconds: int) -> None:
        slot = self.slots[self.slot]
        read_pos = slot.ibi_start
        self.motion[self.motion_pos] = motion_seconds & 0xFF

        seen = 0
        oldest_start = self.slots[(self.slot + 1) % _SLOTS].ibi_start
        # Unsigned 64-bit in the native code: within 30 s of time zero the window start
        # wraps around and no beat counts.
        lower = self.epoch_time - _EPOCH_MS
        # The native loop rescans from the first beat each epoch and stops at the first
        # timestamp past the epoch. Beats already older than a past window can never count
        # again (windows only move forward), so skipping them keeps the result identical.
        skip = self.scan_from
        if lower >= 0:
            while skip < len(ibi_timestamps_ms) and ibi_timestamps_ms[skip] < lower:
                skip += 1
            self.scan_from = skip
        else:
            lower = 1 << 64
        for index in range(skip, len(ibi_values)):
            rr, timestamp = ibi_values[index], ibi_timestamps_ms[index]
            if self.epoch_time < timestamp:
                break
            if lower <= timestamp and rr < 2000:
                following = (slot.ibi_end + 1) % _IBI_RING
                if following != oldest_start:
                    self.ibi_ring[slot.ibi_end] = rr
                    slot.ibi_end = following
                seen += 1
        if not seen:
            self.motion[self.motion_pos] = 0

        if self.epoch_counter != 0:
            bpm_q16 = self._heart_rate_q16()
            heart_rate = min(0xFF, _round_q16(_fix16_mul(bpm_q16, 0x20000)))

            samples_before = self.sample_counter
            while read_pos != slot.ibi_end:
                self._resample(self.ibi_ring[read_pos])
                read_pos = (read_pos + 1) % _IBI_RING
            breathing_rate, variability = self._breathing(self.sample_counter - samples_before)

            if slot.ibi_end in (slot.ibi_start, (slot.ibi_start + 1) % _IBI_RING):
                status, motion_sum = _RECORD_INVALID, 0xF
                variability, breathing_rate, heart_rate = 0x10, 0x50, 0xAA
            else:
                status = self._motion_status()
                w = self.motion_pos
                motion_sum = min(0xFF, sum(self.motion[(w - j) % 16] for j in range(4)))
                self.variability_history[self.variability_pos] = variability
                self.variability_pos = (self.variability_pos + 1) % 4
                heart_rate = max(0, heart_rate)

            if len(self.records) < _MAX_RECORDS:
                self.records.append(EpochRecord(self.epoch_time - _EPOCH_MS, heart_rate,
                                                breathing_rate, variability, motion_sum, status))

        self._advance_slot()
        self.motion_pos = (self.motion_pos + 1) % _MOTION_RING
        self.motion[self.motion_pos] = 0
        self.epoch_time += _EPOCH_MS
        self.epoch_counter += 1


def calculate_epoch_records(
    bedtime_start_ms: int,
    ibi_values: Sequence[int],
    ibi_timestamps_ms: Sequence[int],
    motion_seconds: Sequence[int],
) -> list[EpochRecord]:
    """Per-epoch records exactly as libecore stores them (one per epoch after the first)."""
    if len(ibi_values) != len(ibi_timestamps_ms):
        raise ValueError("ibi_values and ibi_timestamps_ms must have equal length")
    state = _BreathingRateState(bedtime_start_ms)
    state.start()
    for motion in motion_seconds:
        state.epoch(ibi_values, ibi_timestamps_ms, motion)
    return state.records


def calculate_breathing_rate(
    bedtime_start_ms: int,
    ibi_values: Sequence[int],
    ibi_timestamps_ms: Sequence[int],
    motion_seconds: Sequence[int],
) -> BreathingRateOutput:
    """Port of nexus::ecore::ecore_cpp_calculate_breathing_rate (libecore.so).

    bedtime_start_ms: start of the bedtime period, in the same clock as the timestamps.
    ibi_values: beat-to-beat intervals in ms (values >= 2000 are ignored).
    ibi_timestamps_ms: one timestamp per interval, ascending.
    motion_seconds: one value per 30 s epoch (seconds of motion, 0..30); its length is the epoch count.
    """
    epoch_count = len(motion_seconds)
    records = calculate_epoch_records(bedtime_start_ms, ibi_values, ibi_timestamps_ms, motion_seconds)

    first = 0
    cutoff = (bedtime_start_ms - _EPOCH_MS) & 0xFFFF_FFFF_FFFF_FFFF
    for index, record in enumerate(records):
        if cutoff <= record.time_ms & 0xFFFF_FFFF_FFFF_FFFF:
            first = index
            break

    if epoch_count <= 360:
        return BreathingRateOutput(0.0, 0.0, 0.0)
    if epoch_count <= 600:
        start, end = epoch_count // 2 - 180, epoch_count // 2 + 180
    else:
        start, end = first + 120, epoch_count + first - 120
    end = min(end, _MAX_RECORDS)
    if end <= start:
        return BreathingRateOutput(0.0, 0.0, 0.0)

    # Unwritten record slots are pre-filled with status 2, so they never count.
    valid = [r for r in records[start:end] if r.status != _RECORD_INVALID]
    if not valid:
        return BreathingRateOutput(0.0, 0.0, 0.0)

    count = len(valid)
    half = count >> 1
    heart_rate = ((sum(r.heart_rate for r in valid) * 4 + half) // count) & 0xFFFF
    breathing_rate = ((sum(r.breathing_rate for r in valid) + half) // count) & 0xFF
    variability = ((sum(r.variability for r in valid) + half) // count) & 0xFF

    return BreathingRateOutput(
        avg_breathing_rate=_f32(breathing_rate / 8.0),
        avg_breathing_rate_variability=_f32(variability / 8.0),
        avg_heart_rate=_f32(heart_rate / 8.0),
    )


def _self_test() -> None:
    epoch_count = 600
    base_ibi = 1000.0
    amplitude = 30.0
    breathing_hz = 0.25

    ibi_values: list[int] = []
    timestamps: list[int] = []
    time_ms = 0.0
    while time_ms < epoch_count * _EPOCH_MS:
        rr = base_ibi + amplitude * math.sin(2.0 * math.pi * breathing_hz * time_ms / 1000.0)
        rr = max(300.0, min(2000.0, rr))
        ibi_values.append(int(round(rr)))
        timestamps.append(int(round(time_ms)))
        time_ms += rr

    output = calculate_breathing_rate(
        0,
        ibi_values,
        timestamps,
        [0] * epoch_count,
    )

    assert abs(output.avg_breathing_rate - 15.0) < 0.25, output
    assert abs(output.avg_heart_rate - 60.0) < 0.25, output
    print(output)


def _load_latest_bedtime(db_path):
    """Read the newest ring bedtime (0x76) and assemble its IBI series from the DB."""
    import json
    import sqlite3
    from pathlib import Path

    from _common import resolve_db
    from epoch_time import build_epochs, make_unix_s
    from ibi_correction import correct_ibis
    from nssa_inputs import TAG_BEDTIME, collect_nssa_inputs

    repo = Path(__file__).resolve().parent.parent
    db = resolve_db(db_path, repo)
    con = sqlite3.connect(str(db))
    try:
        rows = con.execute(
            "SELECT ring_timestamp, tag, COALESCE(decoded_json, '{}'), captured_unix, body "
            "FROM events WHERE decoded_json IS NOT NULL OR (tag = 65 AND LENGTH(body) >= 14) "
            "ORDER BY captured_unix, id"
        ).fetchall()
    finally:
        con.close()

    epochs = build_epochs([row[:4] for row in rows])
    unix_s = make_unix_s(epochs)

    def ms(ds, captured_unix=None):
        unix = unix_s(ds, captured_unix)
        return int(round(unix * 1000)) if unix is not None else int(ds * 100)

    bedtime = None
    for ds, tag, js, cu, _body in rows:
        if tag != TAG_BEDTIME:
            continue
        value = json.loads(js)
        start_ds, end_ds = value.get("bedtime_start_ds"), value.get("bedtime_end_ds")
        if start_ds is None or end_ds is None or end_ds <= start_ds:
            continue
        bedtime = (start_ds, end_ds, cu)

    if bedtime is None:
        raise SystemExit("error: no bedtime_period (0x76) in the database")

    decoded = [
        (ds, tag, json.loads(js), cu, bytes(body) if body is not None else None)
        for ds, tag, js, cu, body in rows
        if tag in (0x60, 0x72, 0x75)
    ]
    start_ds, end_ds, captured_unix = bedtime
    inputs = collect_nssa_inputs(decoded, start_ds, end_ds, captured_unix, ms, correct_ibis)
    # Ring motion events (0x47 motion_event) carry seconds of motion per period.
    inputs["motion"] = sorted(
        (ms(ds, cu), int(json.loads(js).get("motion_seconds", 0)))
        for ds, tag, js, cu, _body in rows
        if tag == 0x47 and start_ds <= ds <= end_ds
    )
    return db, inputs


def _motion_per_epoch(bedtime_start_ms, epoch_count, motion_events):
    """Seconds of motion per epoch, using the same window as the beats: (t - 30 s, t].

    How the Oura app builds this array is not confirmed; this alignment is an assumption.
    """
    motion = [0] * epoch_count
    for timestamp, seconds in motion_events:
        epoch = -(-(timestamp - bedtime_start_ms) // _EPOCH_MS)
        if 0 <= epoch < epoch_count:
            motion[epoch] = max(0, min(0xFF, motion[epoch] + seconds))
    return motion


def main(argv=None) -> int:
    import argparse
    import json

    parser = argparse.ArgumentParser(
        description="Nightly breathing rate from ring IBI (ecore breathing_rate_calculate_averages)."
    )
    parser.add_argument("db", nargs="?", help="oura.db path (default: ./oura.db or the repo's)")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument("--self-test", action="store_true", help="run the synthetic signal check")
    parser.add_argument("--no-motion", action="store_true", help="ignore 0x47 motion events (all epochs still)")
    args = parser.parse_args(argv)

    if args.self_test:
        _self_test()
        return 0

    db, inputs = _load_latest_bedtime(args.db)
    start_ms, end_ms = inputs["bedtime"]
    epoch_count = max(0, (end_ms - start_ms) // _EPOCH_MS)
    ibi = inputs["ibi"]
    motion = [0] * epoch_count if args.no_motion else _motion_per_epoch(start_ms, epoch_count, inputs["motion"])
    output = calculate_breathing_rate(
        start_ms,
        [beat[1] for beat in ibi],
        [beat[0] for beat in ibi],
        motion,
    )

    if args.json:
        print(json.dumps({
            "db": str(db),
            "bedtime_start_ms": start_ms,
            "bedtime_end_ms": end_ms,
            "epochs": epoch_count,
            "beats": len(ibi),
            "epochs_with_motion": sum(1 for value in motion if value),
            "avg_breathing_rate": output.avg_breathing_rate,
            "avg_breathing_rate_variability": output.avg_breathing_rate_variability,
            "avg_heart_rate": output.avg_heart_rate,
        }))
    else:
        print(
            f"breathing rate {output.avg_breathing_rate:.1f} br/min "
            f"(variability {output.avg_breathing_rate_variability:.1f}, "
            f"heart rate {output.avg_heart_rate:.1f} bpm) "
            f"over {epoch_count} epochs / {len(ibi)} beats"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
