import SwiftUI
import UIKit

/// The last few unattended runs, newest first, so the status screen can show
/// whether background sync is actually happening. Small and UserDefaults-backed:
/// a run's outcome must survive the process being suspended right after it.
enum BackgroundLog {
    struct Entry: Codable, Identifiable {
        let at: Date
        let reason: String
        let synced: Bool
        let exported: Bool
        let note: String
        var id: Date { at }
    }
    private static let key = "bg.log"
    private static let limit = 30

    static func record(reason: String, synced: Bool, exported: Bool, note: String) {
        var entries = load()
        entries.insert(Entry(at: Date(), reason: reason, synced: synced, exported: exported, note: note), at: 0)
        if let data = try? JSONEncoder().encode(Array(entries.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}

/// Home screen: is the ring → Health pipeline healthy, plus the latest result of each
/// on-device Oura model. The full reports open from the Insights section.
struct StatusView: View {
    @ObservedObject var ring: RingSync
    @ObservedObject var health: HealthExport = .shared
    let summary: Summary?
    let onSyncNow: () -> Void
    let onOpenRing: () -> Void
    let onOpenProfile: () -> Void
    let onOpenInsights: () -> Void

    var body: some View {
        // Relative times ("12 min ago") and the background log refresh on their own.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                ringSection(now: context.date)
                insightsSection
                syncSection(now: context.date)
                healthSection(now: context.date)
                backgroundSection(now: context.date)
                Section {
                    Button("Ring, pairing & diagnostics", action: onOpenRing)
                    Button("Body profile", action: onOpenProfile)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Open Oura")
        }
    }

    // ── Ring ──
    @ViewBuilder private func ringSection(now: Date) -> some View {
        let device = summary?.device
        Section("Ring") {
            if let pct = device?.battery_pct {
                LabeledContent("Battery") {
                    HStack(spacing: 6) {
                        Image(systemName: Self.batteryIcon(pct))
                            .foregroundStyle(pct <= 15 ? .red : (pct <= 30 ? .orange : .green))
                        Text("\(pct)%")
                    }
                }
                if let recorded = device?.battery_recorded_hm ?? device?.battery_recorded {
                    LabeledContent("Battery reading", value: recorded)
                }
            } else {
                LabeledContent("Battery", value: "after the next sync")
            }
            LabeledContent("Serial", value: device?.serial ?? ring.knownSerial ?? "not paired")
            if let firmware = device?.firmware { LabeledContent("Firmware", value: firmware) }
            if Keychain.loadKey() == nil {
                Text("No ring paired. Open Ring, pairing & diagnostics to pair one.")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // ── Insights ──
    // One row per on-device model: its latest result, or why there is none yet.
    @ViewBuilder private var insightsSection: some View {
        Section {
            if let s = summary, s.error == nil {
                sleepRow(s)
                cardioRow(s)
                workoutsRow(s)
                radarRow(s)
                if let vo2 = s.fitness?.vo2max {
                    LabeledContent("VO₂max estimate", value: String(format: "%.0f ml/kg/min", vo2))
                }
                ForEach(s.modelErrors, id: \.self) { error in
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Button("Open sleep, activity & heart reports", action: onOpenInsights)
            } else {
                Text("Results appear after the first sync.").font(.footnote).foregroundStyle(.secondary)
            }
            NavigationLink("Models on this phone") { ModelListView() }
        } header: {
            Text("Insights")
        }
    }

    @ViewBuilder private func sleepRow(_ s: Summary) -> some View {
        if let night = s.nights.first(where: \.hasHypnogram) ?? s.nights.first {
            LabeledContent("Last night") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(night.in_bed_h.map { Self.hours($0) + " in bed" } ?? night.date ?? "–")
                    if night.hasHypnogram, let deep = night.deep_pct, let rem = night.rem_pct {
                        Text("deep \(Int(deep))% · REM \(Int(rem))%" + (night.efficiency.map { " · \(Int($0))% efficient" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if night.hasHypnogram {
                        Text(Sleep.isOuraStaging(night.staging_source) ? "staged by Oura's model" : "signal estimate")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            LabeledContent("Last night", value: "no night yet")
        }
    }

    @ViewBuilder private func cardioRow(_ s: Summary) -> some View {
        if let age = s.cardio?.vascular_age {
            LabeledContent("Cardiovascular age") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(age.rounded())) years")
                    if let real = s.cardio?.chronological_age {
                        let gap = age - real
                        Text(abs(gap) < 1 ? "same as your age" : String(format: "%.0f years %@ your age", abs(gap), gap < 0 ? "below" : "above"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } else if ModelFiles.find("cva", validated: "2_1_0") != nil {
            LabeledContent("Cardiovascular age", value: "needs cva_ppg readings")
        }
    }

    @ViewBuilder private func workoutsRow(_ s: Summary) -> some View {
        let workouts = s.workouts.filter { $0.isWorkout > 0.5 }
        if let latest = workouts.max(by: { $0.start < $1.start }) {
            LabeledContent("Latest workout") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(latest.label.capitalized) · \(latest.durationMin) min")
                    Text(latest.start).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if ModelFiles.find("automatic_activity_detection", validated: "3_1_11") != nil {
            LabeledContent("Latest workout", value: "none detected")
        }
    }

    @ViewBuilder private func radarRow(_ s: Summary) -> some View {
        if let radar = s.illness ?? s.symptoms, radar.available {
            LabeledContent("Symptom radar") {
                Text(Self.radarLabel(radar.trafficLight))
                    .foregroundStyle(radar.trafficLight == "MAJOR_SIGNS" ? .red : (radar.trafficLight == "MINOR_SIGNS" ? .orange : .primary))
            }
        }
    }

    private static func radarLabel(_ light: String) -> String {
        switch light {
        case "NO_SIGNS": return "No signs"
        case "MINOR_SIGNS": return "Minor signs"
        case "MAJOR_SIGNS": return "Major signs"
        default: return "Needs more nights"
        }
    }

    private static func hours(_ h: Double) -> String {
        let m = Int((h * 60).rounded())
        return "\(m / 60) h \(m % 60) min"
    }

    // ── Sync ──
    @ViewBuilder private func syncSection(now: Date) -> some View {
        Section {
            LabeledContent("Last sync") {
                if let at = ring.lastSuccessfulSyncAt {
                    Text(Self.ago(at, now: now))
                        .foregroundStyle(Self.staleness(at, now: now))
                } else {
                    Text("never")
                }
            }
            if let report = ring.lastReport {
                LabeledContent("Last sync pulled", value: "\(report.inserted) readings")
            }
            if ring.busy || !ring.status.isEmpty {
                Text(ring.busy ? "Syncing… \(ring.status)" : ring.status)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let issue = ring.connectionIssue {
                Text(issue).font(.footnote).foregroundStyle(.red)
            }
            Button(ring.busy ? "Syncing…" : "Sync now", action: onSyncNow)
                .disabled(ring.busy || Keychain.loadKey() == nil)
        } header: {
            Text("Sync")
        } footer: {
            Text("Syncs whenever the ring reconnects and about hourly otherwise, at most every 15 minutes. Swiping the app away stops background sync until you open it again.")
        }
    }

    // ── Apple Health ──
    @ViewBuilder private func healthSection(now: Date) -> some View {
        Section("Apple Health") {
            Toggle("Write ring data to Health", isOn: Binding(
                get: { health.enabled },
                set: { health.setEnabled($0, summary: summary ?? SummaryCache.load()) }))
            if let at = health.lastExportAt {
                LabeledContent("Last export", value: Self.ago(at, now: now))
            }
            if !health.status.isEmpty {
                Text(health.status).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // ── Background ──
    @ViewBuilder private func backgroundSection(now: Date) -> some View {
        let entries = BackgroundLog.load()
        let lastDay = entries.filter { now.timeIntervalSince($0.at) < 24 * 3600 }
        Section {
            if UIApplication.shared.backgroundRefreshStatus != .available {
                Text("Background App Refresh is off for this app. Turn it on in Settings › General › Background App Refresh.")
                    .font(.footnote).foregroundStyle(.red)
            }
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                Text("Low Power Mode is on, so iOS runs background work less often.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            LabeledContent("Background runs, last 24 h",
                           value: "\(lastDay.count) (\(lastDay.filter(\.synced).count) synced)")
            if entries.isEmpty {
                Text("None yet. They start once the app has been in the background for a while.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(entries.prefix(8)) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: entry.synced ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(entry.synced ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.reason).font(.subheadline)
                        if !entry.note.isEmpty {
                            Text(entry.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(Self.ago(entry.at, now: now)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Background")
        }
    }

    private static func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 48 * 3600 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) days ago"
    }

    /// Green while syncs are flowing, orange after two quiet hours, red after six.
    private static func staleness(_ date: Date, now: Date) -> Color {
        let s = now.timeIntervalSince(date)
        return s < 2 * 3600 ? .green : (s < 6 * 3600 ? .orange : .red)
    }
}

/// Which Oura model files this build bundles, and which version each family runs.
struct ModelListView: View {
    var body: some View {
        List {
            Section {
                ForEach(ModelFiles.known, id: \.family) { model in
                    let all = ModelFiles.bundled(model.family)
                    let picked = ModelFiles.find(model.family, validated: model.validated)
                    LabeledContent(model.title) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(picked.map { "v" + ModelFiles.display($0.version) } ?? "not bundled")
                                .foregroundStyle(picked == nil ? .secondary : .primary)
                            if let picked, picked.version != model.validated {
                                Text("tested on v\(ModelFiles.display(model.validated))")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            if all.count > 1 {
                                Text("\(all.count) versions bundled").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Oura's models are decrypted and exported on your Mac (tools/export_mobile.py) and bundled at build time. A missing model only hides its result.")
            }
        }
        .navigationTitle("Models")
    }
}
