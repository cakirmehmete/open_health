import SwiftUI
import Charts

// The Insights tab: the latest result of each on-device model and vital, in the look of
// Oura's own app (dark cards, a range slider per metric, banded trend charts, and a
// contributors list). Data comes from the same Summary the reports render.

enum Ink {
    static let canvas = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let card = Color(red: 0.13, green: 0.14, blue: 0.17)
    static let line = Color.white.opacity(0.12)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.55)
    static let good = Color(red: 0.42, green: 0.80, blue: 0.70)
    static let fair = Color(red: 0.86, green: 0.80, blue: 0.52)
    static let warn = Color(red: 0.88, green: 0.56, blue: 0.46)
}

/// A judged result, shown as the small caps label under a card title.
enum Tone {
    case optimal, good, fair, attention, neutral
    var label: String {
        switch self {
        case .optimal: return "Optimal"
        case .good: return "Good"
        case .fair: return "Fair"
        case .attention: return "Pay attention"
        case .neutral: return ""
        }
    }
    var color: Color {
        switch self {
        case .optimal, .good: return Ink.good
        case .fair: return Ink.fair
        case .attention: return Ink.warn
        case .neutral: return Ink.dim
        }
    }
}

/// Personal range for a nightly series: the 10th–90th percentile of recent nights.
struct PersonalRange {
    let lower: Double
    let upper: Double
    init(lower: Double, upper: Double) { self.lower = lower; self.upper = upper }
    init?(_ values: [Double]) {
        let v = values.sorted()
        guard v.count >= 5 else { return nil }
        func q(_ p: Double) -> Double { v[min(v.count - 1, max(0, Int((Double(v.count - 1) * p).rounded())))] }
        lower = q(0.1); upper = q(0.9)
        guard upper > lower else { return nil }
    }
    /// Inside the range is optimal; a little outside is fair; well outside, attention.
    func tone(_ x: Double) -> Tone {
        let pad = (upper - lower) * 0.5
        if x >= lower && x <= upper { return .optimal }
        if x >= lower - pad && x <= upper + pad { return .fair }
        return .attention
    }
}

struct InsightsView: View {
    let summary: Summary?
    let onOpenReports: () -> Void
    @AppStorage("insights.stepGoal") private var stepGoal = 8000.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let s = summary, s.error == nil {
                    rings(s)
                    sleepCard(s)
                    breathingCard(s)
                    activityCard(s)
                    vitalCard(s, .hrv, title: "Heart rate variability", icon: "waveform.path.ecg")
                    vitalCard(s, .heartRate, title: "Resting heart rate", icon: "heart")
                    vitalCard(s, .temp, title: "Skin temperature", icon: "thermometer.medium")
                    vitalCard(s, .oxygen, title: "Blood oxygen", icon: "drop")
                    cardioCard(s)
                    radarCard(s)
                    workoutsCard(s)
                    Button(action: onOpenReports) {
                        Label("Full sleep, activity & heart reports", systemImage: "chart.xyaxis.line")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered).tint(Ink.text)
                } else {
                    Text("Results appear after the first sync.")
                        .foregroundStyle(Ink.dim).padding(.top, 40)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Ink.canvas.ignoresSafeArea())
        .navigationTitle("Today")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    // ── score rings ──
    @ViewBuilder private func rings(_ s: Summary) -> some View {
        let night = lastNight(s)
        let steps = todayStats(s)?.steps
        let hrv = s.vitals.hrv
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ScoreRing(label: "Sleep", icon: "moon",
                          fraction: night?.efficiency.map { $0 / 100 },
                          text: night?.efficiency.map { "\(Int($0))" })
                ScoreRing(label: "Activity", icon: "flame",
                          fraction: steps.map { min(1, $0 / stepGoal) },
                          text: steps.map { "\(Int(min(999, $0 / stepGoal * 100)))" })
                ScoreRing(label: "HRV", icon: "waveform.path.ecg",
                          fraction: hrv.latest.flatMap { l in hrv.baseline.map { b in min(1, l / max(1, b * 1.25)) } },
                          text: hrv.latest.map { "\(Int($0))" })
                if let age = s.cardio?.vascular_age {
                    ScoreRing(label: "Heart age", icon: "heart", fraction: nil, text: "\(Int(age.rounded()))")
                }
            }
            .padding(.vertical, 6)
        }
    }

    // ── cards ──
    @ViewBuilder private func sleepCard(_ s: Summary) -> some View {
        if let night = lastNight(s) {
            let hours = night.in_bed_h ?? 0
            let need = s.sleepDebt?.need_h ?? 8
            let tone: Tone = night.efficiency.map { $0 >= 85 ? .optimal : ($0 >= 75 ? .fair : .attention) } ?? .neutral
            Button(action: onOpenReports) {
                InsightCard(icon: "moon", title: "Sleep", tone: tone,
                            value: Self.hm(hours), unit: "in bed") {
                    VStack(alignment: .leading, spacing: 8) {
                        RangeSlider(lower: need - 0.5, upper: need + 1, value: hours,
                                    domain: (need - 3)...(need + 3),
                                    format: { Self.hm($0) })
                        if night.hasHypnogram, let deep = night.deep_pct, let rem = night.rem_pct, let light = night.light_pct {
                            StageStrip(deep: deep, light: light, rem: rem, wake: night.wake_pct ?? 0)
                            Text(Sleep.isOuraStaging(night.staging_source) ? "Staged by Oura's model" : "Signal estimate")
                                .font(.caption2).foregroundStyle(Ink.dim)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // Oura's SleepNet-BDI: the model calls a night elevated at ODI >= 15 % of sleep epochs.
    @ViewBuilder private func breathingCard(_ s: Summary) -> some View {
        if let b = lastNight(s)?.breathing {
            let ok = b.status == 1
            let odi = b.odi_pct ?? 0
            let normal = PersonalRange(lower: 0, upper: 15)
            NavigationLink {
                BreathingDetail(series: s.nightlySeries { $0.breathing?.status == 1 ? $0.breathing?.odi_pct : nil },
                                latest: b, normal: normal)
            } label: {
                InsightCard(icon: "lungs", title: "Breathing disturbances",
                            tone: !ok ? .neutral : (b.elevated == true ? .attention : (odi >= 7.5 ? .fair : .optimal)),
                            value: ok ? String(format: "%.1f", b.events_per_hour ?? 0) : "–",
                            unit: ok ? "per hour" : "") {
                    if ok {
                        VStack(alignment: .leading, spacing: 4) {
                            RangeSlider(lower: normal.lower, upper: normal.upper, value: odi,
                                        domain: 0...max(30, odi), format: { "\(Int($0))%" })
                            Text(String(format: "%.1f%% of sleep flagged by Oura's breathing model", odi))
                                .font(.caption).foregroundStyle(Ink.dim)
                        }
                    } else {
                        Text(b.status == 3 ? "Under 3 h of sleep last night, so no verdict."
                                           : "Too few clean heartbeats last night for a verdict.")
                            .font(.caption).foregroundStyle(Ink.dim)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func activityCard(_ s: Summary) -> some View {
        if let today = todayStats(s), let steps = today.steps {
            InsightCard(icon: "flame", title: "Activity goal",
                        tone: steps >= stepGoal ? .optimal : (steps >= stepGoal * 0.5 ? .fair : .attention),
                        value: "\(Int(min(999, steps / stepGoal * 100)))", unit: "%") {
                VStack(alignment: .leading, spacing: 6) {
                    RangeSlider(lower: stepGoal, upper: stepGoal * 1.5, value: steps,
                                domain: 0...max(stepGoal * 1.5, steps), format: { "\(Int($0))" })
                    HStack {
                        Text("\(Int(steps)) steps")
                        if let kcal = today.active_kcal { Text("· \(Int(kcal)) active kcal") }
                    }
                    .font(.caption).foregroundStyle(Ink.dim)
                }
            }
        }
    }

    @ViewBuilder private func vitalCard(_ s: Summary, _ kind: VitalKind, title: String, icon: String) -> some View {
        let series = kind.series(in: s)
        if let latest = series.last {
            let range = PersonalRange(series.suffix(60).map(\.value))
            NavigationLink {
                VitalInsightDetail(title: title, kind: kind, series: series, range: range)
            } label: {
                InsightCard(icon: icon, title: title, tone: range?.tone(latest.value) ?? .neutral,
                            value: Self.format(latest.value, kind.decimals), unit: kind.unit) {
                    if let range {
                        RangeSlider(lower: range.lower, upper: range.upper, value: latest.value,
                                    domain: Self.domain(range, latest.value),
                                    format: { Self.format($0, kind.decimals) })
                    } else {
                        Text("Your range appears after five nights.").font(.caption).foregroundStyle(Ink.dim)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func cardioCard(_ s: Summary) -> some View {
        if let age = s.cardio?.vascular_age {
            let real = s.cardio?.chronological_age ?? age
            let gap = age - real
            InsightCard(icon: "heart.text.square", title: "Cardiovascular age",
                        tone: gap <= -1 ? .optimal : (gap < 2 ? .good : .attention),
                        value: "\(Int(age.rounded()))", unit: "years") {
                VStack(alignment: .leading, spacing: 6) {
                    RangeSlider(lower: real - 5, upper: real + 2, value: age,
                                domain: (real - 15)...(real + 15), format: { "\(Int($0.rounded()))" })
                    Text(abs(gap) < 1 ? "Same as your age" : String(format: "%.0f years %@ your age", abs(gap), gap < 0 ? "below" : "above"))
                        .font(.caption).foregroundStyle(Ink.dim)
                }
            }
        } else if ModelFiles.find("cva") != nil {
            InsightCard(icon: "heart.text.square", title: "Cardiovascular age", tone: .neutral, value: "–", unit: "") {
                Text("Needs the ring's cva_ppg readings.").font(.caption).foregroundStyle(Ink.dim)
            }
        }
    }

    @ViewBuilder private func radarCard(_ s: Summary) -> some View {
        if let radar = s.illness ?? s.symptoms, radar.available {
            let flagged = radar.biomarkers.filter(\.indicatesSymptoms).count
            NavigationLink {
                SymptomRadarDetail(radar: radar)
            } label: {
                InsightCard(icon: "sensor.tag.radiowaves.forward", title: "Symptom radar",
                            tone: radar.trafficLight == "MAJOR_SIGNS" ? .attention : (radar.trafficLight == "MINOR_SIGNS" ? .fair : .optimal),
                            value: radar.trafficLight == "NO_SIGNS" ? "No signs" : "\(flagged) signs", unit: "") {
                    Text("\(radar.biomarkers.count) biomarkers against your own baseline")
                        .font(.caption).foregroundStyle(Ink.dim)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func workoutsCard(_ s: Summary) -> some View {
        let recent = s.workouts.filter { $0.isWorkout > 0.5 }.sorted { $0.start > $1.start }.prefix(3)
        if !recent.isEmpty {
            InsightCard(icon: "figure.run", title: "Workouts", tone: .neutral,
                        value: "\(recent.first!.durationMin)", unit: "min \(recent.first!.label.lowercased())") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(recent)) { w in
                        HStack {
                            Text(w.label.capitalized)
                            Spacer()
                            Text("\(w.start) · \(w.durationMin) min").foregroundStyle(Ink.dim)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    // ── helpers ──
    private func lastNight(_ s: Summary) -> NightRow? {
        s.days.first.flatMap { s.night(forDay: $0) } ?? s.nights.first
    }
    private func todayStats(_ s: Summary) -> DailyStat? {
        s.activity_daily.keys.max().flatMap { s.activity_daily[$0] }
    }
    static func hm(_ h: Double) -> String {
        let m = Int((h * 60).rounded())
        return "\(m / 60)h \(m % 60)m"
    }
    static func format(_ x: Double, _ decimals: Int) -> String { String(format: "%.\(decimals)f", x) }
    static func domain(_ r: PersonalRange, _ x: Double) -> ClosedRange<Double> {
        let pad = (r.upper - r.lower) * 0.8
        return min(r.lower - pad, x)...max(r.upper + pad, x)
    }
}

// ── building blocks ──

struct InsightCard<Content: View>: View {
    let icon: String
    let title: String
    let tone: Tone
    let value: String
    let unit: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 13))
                    .frame(width: 28, height: 28)
                    .background(Circle().stroke(Ink.line))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).foregroundStyle(Ink.text)
                    if tone != .neutral {
                        Text(tone.label.uppercased()).font(.caption2.weight(.semibold))
                            .tracking(1).foregroundStyle(tone.color)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Ink.dim)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 38, weight: .light)).foregroundStyle(Ink.text)
                if !unit.isEmpty { Text(unit).font(.subheadline).foregroundStyle(Ink.dim) }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Ink.card, tone.color.opacity(0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .foregroundStyle(Ink.text)
    }
}

/// A thin track with the healthy range drawn bright and a knob at today's value.
struct RangeSlider: View {
    let lower: Double
    let upper: Double
    let value: Double
    let domain: ClosedRange<Double>
    let format: (Double) -> String

    private func x(_ v: Double, _ w: CGFloat) -> CGFloat {
        let span = max(domain.upperBound - domain.lowerBound, .ulpOfOne)
        return CGFloat((min(max(v, domain.lowerBound), domain.upperBound) - domain.lowerBound) / span) * w
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.line).frame(height: 3).offset(y: -8)
                Capsule().fill(Ink.text.opacity(0.85))
                    .frame(width: max(2, x(upper, w) - x(lower, w)), height: 3)
                    .offset(x: x(lower, w), y: -8)
                Circle().fill(Ink.text).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Ink.canvas, lineWidth: 2))
                    .offset(x: x(value, w) - 7, y: -8)
                Text(format(lower)).font(.caption2).foregroundStyle(Ink.dim)
                    .fixedSize().position(x: x(lower, w), y: 18)
                Text(format(upper)).font(.caption2).foregroundStyle(Ink.dim)
                    .fixedSize().position(x: x(upper, w), y: 18)
            }
        }
        .frame(height: 34)
    }
}

/// Deep / light / REM / awake as one proportional bar.
struct StageStrip: View {
    let deep: Double, light: Double, rem: Double, wake: Double
    private struct Part: Identifiable { let id: Int; let share: Double; let color: Color }
    var body: some View {
        let parts = [Part(id: 0, share: deep, color: Color(red: 0.36, green: 0.45, blue: 0.85)),
                     Part(id: 1, share: light, color: Color(red: 0.55, green: 0.68, blue: 0.95)),
                     Part(id: 2, share: rem, color: Ink.good),
                     Part(id: 3, share: wake, color: Color.white.opacity(0.5))]
        let total = max(deep + light + rem + wake, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts) { part in
                        Capsule().fill(part.color).frame(width: max(0, geo.size.width * part.share / total - 2))
                    }
                }
            }
            .frame(height: 6)
            Text("deep \(Int(deep))% · light \(Int(light))% · REM \(Int(rem))% · awake \(Int(wake))%")
                .font(.caption2).foregroundStyle(Ink.dim)
        }
    }
}

struct ScoreRing: View {
    let label: String
    let icon: String
    let fraction: Double?
    let text: String?
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Ink.line, lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(fraction ?? 0))
                    .stroke(Ink.text, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Image(systemName: icon).font(.system(size: 9)).foregroundStyle(Ink.dim)
                    Text(text ?? "–").font(.system(size: 17, weight: .medium))
                }
            }
            .frame(width: 58, height: 58)
            Text(label).font(.caption2).foregroundStyle(Ink.dim)
        }
        .foregroundStyle(Ink.text)
    }
}

/// Low / Normal / High bands from the personal range, with the nightly line on top.
struct BandedTrendChart: View {
    let points: [DatedVital]
    let range: PersonalRange?
    let decimals: Int
    @State private var selected: String?
    private struct Point { let date: Date; let value: Double; let key: String }

    private static let parse: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let dated = points.compactMap { p in Self.parse.date(from: p.date).map { Point(date: $0, value: p.value, key: p.date) } }
        let values = dated.map(\.value)
        let lo = min(values.min() ?? 0, range?.lower ?? .infinity)
        let hi = max(values.max() ?? 1, range?.upper ?? -.infinity)
        let pad = max((hi - lo) * 0.25, 0.5)
        let focus = dated.first { $0.key == selected } ?? dated.last
        Chart {
            if let range {
                RectangleMark(yStart: .value("", lo - pad), yEnd: .value("", range.lower))
                    .foregroundStyle(Color.white.opacity(0.02))
                RectangleMark(yStart: .value("", range.lower), yEnd: .value("", range.upper))
                    .foregroundStyle(Ink.good.opacity(0.08))
                RuleMark(y: .value("", range.lower)).foregroundStyle(Ink.line)
                RuleMark(y: .value("", range.upper)).foregroundStyle(Ink.line)
            }
            ForEach(dated, id: \.key) { p in
                LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Ink.fair, Ink.good], startPoint: .leading, endPoint: .trailing))
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            if let focus {
                RuleMark(x: .value("Day", focus.date)).foregroundStyle(Ink.dim)
                PointMark(x: .value("Day", focus.date), y: .value("Value", focus.value))
                    .symbolSize(90).foregroundStyle(Ink.good)
                    .annotation(position: .top) {
                        Text(String(format: "%.\(decimals)f", focus.value))
                            .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Ink.text)).foregroundStyle(Ink.canvas)
                    }
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
        .chartYAxis {
            if let range {
                AxisMarks(position: .trailing, values: [range.lower, range.upper]) { v in
                    AxisValueLabel { Text(v.as(Double.self) == range.lower ? "Low" : "High").foregroundStyle(Ink.dim) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        guard let date: Date = proxy.value(atX: g.location.x) else { return }
                        selected = dated.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.key
                    })
            }
        }
        .frame(height: 240)
    }
}

/// A labelled bar whose fill and status mirror Oura's contributors list.
struct ContributorRow: View {
    let label: String
    let tone: Tone
    let fraction: Double
    let detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).foregroundStyle(Ink.text)
                Spacer()
                Text(tone.label).foregroundStyle(tone == .attention ? Ink.warn : Ink.text)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.line)
                    Capsule().fill(tone == .attention ? Ink.warn : Ink.text)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0.04, fraction))))
                }
            }
            .frame(height: 4)
            if let detail { Text(detail).font(.caption).foregroundStyle(Ink.dim) }
        }
        .padding(.vertical, 6)
    }
}

// ── detail pages ──

struct VitalInsightDetail: View {
    let title: String
    let kind: VitalKind
    let series: [DatedVital]
    let range: PersonalRange?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BandedTrendChart(points: Array(series.suffix(180)), range: range, decimals: kind.decimals)
                    .padding(.top, 8)
                Text(kind.caption).font(.footnote).foregroundStyle(Ink.dim)
                if let range, let latest = series.last {
                    Text("Contributors").font(.title3).foregroundStyle(Ink.text)
                    ContributorRow(label: "Last night", tone: range.tone(latest.value),
                                   fraction: position(latest.value, range),
                                   detail: "\(InsightsView.format(latest.value, kind.decimals)) \(kind.unit), your range \(InsightsView.format(range.lower, kind.decimals))–\(InsightsView.format(range.upper, kind.decimals))")
                    let week = series.suffix(7).map(\.value)
                    if week.count >= 3 {
                        let mean = week.reduce(0, +) / Double(week.count)
                        ContributorRow(label: "7-night average", tone: range.tone(mean), fraction: position(mean, range),
                                       detail: "\(InsightsView.format(mean, kind.decimals)) \(kind.unit)")
                    }
                    let inRange = series.suffix(30).filter { $0.value >= range.lower && $0.value <= range.upper }.count
                    let n = min(30, series.count)
                    ContributorRow(label: "Nights in your range", tone: Double(inRange) / Double(max(n, 1)) >= 0.7 ? .optimal : .fair,
                                   fraction: Double(inRange) / Double(max(n, 1)),
                                   detail: "\(inRange) of the last \(n)")
                }
            }
            .padding(16)
        }
        .background(Ink.canvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    /// 0…1 along the bar: the middle of your range is 0.9 (Oura draws a healthy
    /// contributor mostly full) and the bar shortens the further a value strays.
    private func position(_ x: Double, _ r: PersonalRange) -> Double {
        let mid = (r.lower + r.upper) / 2, half = (r.upper - r.lower) / 2
        return max(0.05, 0.9 - 0.3 * abs(x - mid) / max(half, .ulpOfOne))
    }
}

struct SymptomRadarDetail: View {
    let radar: IllnessResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(radar.trafficLight == "NO_SIGNS" ? "No signs of strain" :
                     radar.trafficLight == "MAJOR_SIGNS" ? "Major signs of strain" : "Minor signs of strain")
                    .font(.title2).foregroundStyle(Ink.text)
                Text("Each biomarker is judged against your own recent nights (\(radar.daysWithData) days of data).")
                    .font(.footnote).foregroundStyle(Ink.dim)
                Text("Contributors").font(.title3).foregroundStyle(Ink.text).padding(.top, 8)
                ForEach(radar.biomarkers) { b in
                    let span = max(b.upper - b.lower, .ulpOfOne)
                    let outside = b.value < b.lower ? (b.lower - b.value) / span : (b.value > b.upper ? (b.value - b.upper) / span : 0)
                    ContributorRow(label: Self.name(b.type),
                                   tone: b.indicatesSymptoms ? .attention : (outside > 0 ? .fair : .optimal),
                                   fraction: max(0.1, 0.9 - outside),
                                   detail: String(format: "%.1f (your range %.1f–%.1f)", b.value, b.lower, b.upper)
                                       + (b.reason.map { " · \($0.lowercased())" } ?? ""))
                }
            }
            .padding(16)
        }
        .background(Ink.canvas.ignoresSafeArea())
        .navigationTitle("Symptom radar")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    static func name(_ type: String) -> String {
        switch type {
        case "AverageBreath": return "Breathing rate"
        case "LowestHeartRate": return "Lowest heart rate"
        case "AverageHrv": return "Heart rate variability"
        case "TemperatureDeviation": return "Temperature regulation"
        default: return type
        }
    }
}

struct BreathingDetail: View {
    let series: [DatedVital]
    let latest: Breathing
    let normal: PersonalRange

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Share of sleep with a likely breathing disturbance, per night")
                    .font(.footnote).foregroundStyle(Ink.dim)
                BandedTrendChart(points: Array(series.suffix(180)), range: normal, decimals: 1)
                Text("Contributors").font(.title3).foregroundStyle(Ink.text)
                if let odi = latest.odi_nrem_pct {
                    ContributorRow(label: "Non-REM sleep", tone: normal.tone(odi), fraction: 1 - min(1, odi / 30),
                                   detail: String(format: "%.1f%% of non-REM epochs flagged", odi))
                }
                if let odi = latest.odi_rem_pct {
                    ContributorRow(label: "REM sleep", tone: normal.tone(odi), fraction: 1 - min(1, odi / 30),
                                   detail: String(format: "%.1f%% of REM epochs flagged", odi))
                }
                if let min = latest.total_sleep_min {
                    ContributorRow(label: "Sleep analysed", tone: min >= 360 ? .optimal : .fair,
                                   fraction: min / 480, detail: InsightsView.hm(min / 60))
                }
                Text("Oura's model flags 30-second epochs from your heartbeat; it is not a sleep apnea test. A night counts as elevated at 15 % or more.")
                    .font(.caption).foregroundStyle(Ink.dim)
            }
            .padding(16)
        }
        .background(Ink.canvas.ignoresSafeArea())
        .navigationTitle("Breathing")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}
