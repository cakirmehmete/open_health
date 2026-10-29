import SwiftUI
import Charts

// Results of Oura's on-device models that the home and the day reports show in the
// same Obs vocabulary as everything else: SleepNet-BDI breathing disturbances (per
// night, BreathingModel) and daytime stress (per day, StressModel). Both render only
// what the model returned; a night or day the model skipped shows nothing.

private func hm(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

/// One night's SleepNet-BDI result. Status 1 = a verdict, 3 = under 3 h of sleep,
/// 4 = too few clean beats.
struct BreathingSection: View {
    let breathing: Breathing
    /// `odi_pct` of earlier nights with a verdict, oldest first.
    var history: [Double] = []

    private var tint: Color { breathing.elevated == true ? Obs.alert : Obs.ink }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if breathing.status == 1 {
                HStack(alignment: .top, spacing: 0) {
                    Readout(value: String(format: "%.1f", breathing.events_per_hour ?? 0),
                            caption: "per hour", accent: tint)
                    Readout(value: String(format: "%.1f%%", breathing.odi_pct ?? 0),
                            caption: "of sleep", accent: tint)
                    if let nrem = breathing.odi_nrem_pct {
                        Readout(value: String(format: "%.1f%%", nrem), caption: "non-rem")
                    }
                    if let rem = breathing.odi_rem_pct {
                        Readout(value: String(format: "%.1f%%", rem), caption: "rem")
                    }
                }
                if history.count > 1 {
                    Sparkline(series: history, accent: Obs.chart, baseline: 15).frame(height: 34)
                }
                Text(breathing.elevated == true
                     ? "Elevated: Oura's model flagged 15 % or more of sleep with a likely breathing disturbance."
                     : "Within the usual range: under 15 % of sleep flagged.")
                    .font(Obs.prose(14)).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(breathing.status == 3 ? "Under 3 h of sleep, so the model gives no verdict."
                                           : "Too few clean heartbeats for a verdict.")
                    .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
            }
            Text("Flagged from your heartbeat by Oura's SleepNet-BDI model. Not a sleep apnea test.")
                .font(Obs.mono(10)).foregroundStyle(Obs.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A day's stressed / neutral / restored minutes as one bar.
struct StressBar: View {
    let day: StressDay
    var body: some View {
        let parts: [(Int, Color)] = [(day.stressed_min, Obs.bad), (day.neutral_min, Obs.rule),
                                     (day.restored_min, Obs.good)]
        let total = max(1, parts.map(\.0).reduce(0, +))
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if part.0 > 0 {
                        Capsule().fill(part.1)
                            .frame(width: max(4, geo.size.width * CGFloat(part.0) / CGFloat(total) - 2))
                    }
                }
            }
        }
        .frame(height: 8)
    }
}

/// One day of Oura's daytime stress model: minutes per zone, and that day's readings
/// against the stressed / restored limits the model itself returned.
struct StressDaySection: View {
    let stress: DaytimeStress
    let day: StressDay

    /// The model's readings that fall on `day` (local calendar day, as StressModel bins them).
    private var samples: [StressSample] {
        let tz = Double(TimeZone.current.secondsFromGMT())
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return stress.samples.filter { fmt.string(from: Date(timeIntervalSince1970: $0.unix + tz)) == day.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                Readout(value: hm(day.stressed_min), caption: "stressed", accent: Obs.bad)
                Readout(value: hm(day.neutral_min), caption: "neutral")
                Readout(value: hm(day.restored_min), caption: "restored", accent: Obs.good)
            }
            StressBar(day: day)
            let shown = samples
            if shown.count > 1 { chart(shown) }
            Text("\(day.samples) calm awake HRV readings · awake baseline \(Int(day.dhrv_baseline.rounded())) ms · night \(Int(day.night_hrv_baseline.rounded())) ms")
                .font(Obs.mono(10)).foregroundStyle(Obs.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func chart(_ shown: [StressSample]) -> some View {
        let low = shown.compactMap(\.stress_limit_scaled).max() ?? -0.1
        let high = shown.compactMap(\.recovery_limit_scaled).min() ?? 0.1
        let values = shown.map(\.intensity_scaled)
        let lo = min(values.min() ?? -1, low) - 0.15, hi = max(values.max() ?? 1, high) + 0.15
        Chart {
            RectangleMark(yStart: .value("", lo), yEnd: .value("", low)).foregroundStyle(Obs.bad.opacity(0.08))
            RectangleMark(yStart: .value("", high), yEnd: .value("", hi)).foregroundStyle(Obs.good.opacity(0.08))
            RuleMark(y: .value("", low)).foregroundStyle(Obs.rule)
            RuleMark(y: .value("", high)).foregroundStyle(Obs.rule)
            ForEach(shown) { p in
                PointMark(x: .value("Time", Date(timeIntervalSince1970: p.unix)),
                          y: .value("Stress", p.intensity_scaled))
                    .foregroundStyle(p.zone == "stressed" ? Obs.bad : p.zone == "restored" ? Obs.good : Obs.chart)
                    .symbolSize(28)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour(), centered: false)
                    .font(Obs.mono(9)).foregroundStyle(Obs.ink2)
            }
        }
        .frame(height: 120)
    }
}
