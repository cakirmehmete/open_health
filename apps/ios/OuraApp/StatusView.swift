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

/// Status tab: is the ring → Health pipeline healthy, and which Oura models ran.
/// Model results are on the Today tab (InsightsView).
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

    // ── Models ──
    // Results live on the Today tab; status keeps which models ran and what failed.
    @ViewBuilder private var insightsSection: some View {
        Section {
            ForEach(summary?.modelErrors ?? [], id: \.self) { error in
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            NavigationLink("Models on this phone") { ModelListView() }
            Button("Full sleep, activity & heart reports", action: onOpenInsights)
                .disabled(summary == nil)
        } header: {
            Text("Oura models")
        }
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
