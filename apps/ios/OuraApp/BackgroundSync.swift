import BackgroundTasks
import UIKit

/// Keeps ring → Apple Health flowing without the app on screen, so a reader such
/// as Bevel sees fresh data. Nothing here runs after the app is swiped away from
/// the switcher. Each run drains the ring, rebuilds the summary, and exports it.
///
/// What wakes us, most frequent first:
/// - RingWatcher: the ring (re)connecting to its standing link.
/// - Health background delivery: the iPhone's own step count updating (≈ hourly).
/// - BGTasks as the backstop. refresh: short slots, enough for an incremental
///   drain (a longer one checkpoints and resumes); processing: longer slots,
///   typically while the phone sits idle overnight.
///
/// Health refuses writes while the phone is locked. A run that syncs the ring but
/// can't export leaves the fingerprint unsaved, so the next unlocked run retries.
@MainActor
enum BackgroundSync {
    static let refreshID = "md.thomas.openoura.refresh"
    static let processingID = "md.thomas.openoura.sync"
    /// Ask to run about this often. iOS treats it as a floor, not a schedule.
    static let interval: TimeInterval = 45 * 60
    /// Event-driven wakes closer than this to the last good sync are ignored: each
    /// sync costs ring battery, and a few minutes of data isn't worth it.
    static let minimumGap: TimeInterval = 15 * 60
    private static let lastWakeKey = "bg.last-wake-at"

    /// Registration must finish before the app finishes launching.
    static func register() {
        for id in [refreshID, processingID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
                MainActor.assumeIsolated { handle(task) }
            }
        }
    }

    static func schedule() {
        guard Keychain.loadKey() != nil || WhoopLink.isSetUp else { return }
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        processing.requiresExternalPower = false
        processing.requiresNetworkConnectivity = false
        for request in [refresh, processing] as [BGTaskRequest] {
            do { try BGTaskScheduler.shared.submit(request) }
            catch { dlog("bg", "submit \(request.identifier) failed: \(error)") }
        }
    }

    /// An event-driven cue (ring connect, Health update). The foreground UI runs
    /// its own sync, so this only acts while the app is in the background, inside
    /// the ~30 s of background time iOS grants; Bluetooth traffic during the drain
    /// keeps the app awake past that under the bluetooth-central mode.
    static func wake(reason: String, completion: (() -> Void)? = nil) {
        // Gate on the last *attempt*, not the last success: a failing sync must not
        // retry on every wake. Our own Health step writes fire the step observer, and
        // each aborted sync drops the link, which the watcher reconnects (another
        // wake), so gating on success alone looped about once a minute.
        let now = Date()
        let lastAttempt = UserDefaults.standard.object(forKey: lastWakeKey) as? Date
        let recent = [RingSync.shared.lastSuccessfulSyncAt, lastAttempt]
            .compactMap { $0 }.contains { now.timeIntervalSince($0) < minimumGap }
        guard UIApplication.shared.applicationState != .active,
              !WorkCoordinator.shared.backgroundSession else {
            completion?()
            return
        }
        if recent {
            // No ring sync yet, but a sync that ran while the phone was locked left
            // its Health write undone. The step observer only fires once Health is
            // readable again, i.e. unlocked: the moment to deliver it.
            flushPendingExport(reason: reason, completion: completion)
            return
        }
        UserDefaults.standard.set(now, forKey: lastWakeKey)
        // When this ~30 s grant runs out, do NOT pause the sync: the bluetooth-central
        // background mode keeps the app running while ring traffic flows. Pausing here
        // cut every connect-triggered sync off before the drain began.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "ring-wake") {
            dlog("bg", "\(reason) background grant ended; leaving the drain to Bluetooth")
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        Task { @MainActor in
            _ = await run(reason: reason)
            if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
            completion?()
        }
    }

    /// Writes the last background summary to Health if its export is still owed.
    static func flushPendingExport(reason: String, completion: (() -> Void)? = nil) {
        guard HealthExport.shared.enabled, HealthExport.exportPending,
              UIApplication.shared.isProtectedDataAvailable,
              let summary = SummaryCache.load(), summary.error == nil else {
            completion?()
            return
        }
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "health-flush") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        Task { @MainActor in
            let exported = await HealthExport.shared.pushAndWait(summary)
            dlog("bg", "pending Health export after \(reason): exported=\(exported)")
            BackgroundLog.record(reason: "Phone unlocked", synced: false, exported: exported,
                                 note: exported ? "Health updated with the last sync" : "Health still unavailable")
            if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
            completion?()
        }
    }

    private static func handle(_ task: BGTask) {
        // Queue the next slot first: a run that iOS expires still keeps the chain alive.
        schedule()
        let work = Task { @MainActor in
            let ok = await run(reason: task.identifier)
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = {
            Task { @MainActor in
                dlog("bg", "\(task.identifier) expired")
                RingSync.shared.pause()
                WorkCoordinator.shared.invalidateAnalysis()
            }
            work.cancel()
        }
    }

    /// One unattended pass. Returns whether the data reached Health (or export is off).
    static func run(reason: String) async -> Bool {
        let coordinator = WorkCoordinator.shared
        guard !coordinator.backgroundSession else { return false }
        coordinator.backgroundSession = true
        defer { coordinator.backgroundSession = false }
        let started = Date()
        dlog("bg", "start \(reason) locked=\(!UIApplication.shared.isProtectedDataAvailable)")
        // The strap has its own link and drain; a wake is just a cue to check on it.
        WhoopLink.shared.kick(reason: describe(reason))
        let report = await RingSync.shared.syncAutomaticallyIfNeeded()
        dlog("bg", "ring sync \(report == nil ? "skipped or failed" : "done") status=\(RingSync.shared.status)")
        let label = describe(reason)
        guard !Task.isCancelled else {
            BackgroundLog.record(reason: label, synced: report != nil, exported: false, note: "iOS ended the run early")
            return false
        }

        guard let summary = await summarize(), summary.error == nil else {
            dlog("bg", "summary unavailable")
            BackgroundLog.record(reason: label, synced: report != nil, exported: false,
                                 note: report == nil ? RingSync.shared.status : "analysis didn't finish")
            return false
        }
        SummaryCache.save(summary)
        let exported = HealthExport.shared.enabled ? await HealthExport.shared.pushAndWait(summary) : true
        dlog("bg", "end \(reason) exported=\(exported) duration=\(Int(Date().timeIntervalSince(started)))s")
        let note = [report.map { "\($0.inserted) readings" } ?? (RingSync.shared.status.isEmpty ? "ring sync skipped" : RingSync.shared.status),
                    exported ? nil : "Health write pending (phone locked?)"]
            .compactMap { $0 }.joined(separator: " · ")
        BackgroundLog.record(reason: label, synced: report != nil, exported: exported, note: note)
        return exported
    }

    private static func describe(_ reason: String) -> String {
        switch reason {
        case refreshID: return "Scheduled refresh"
        case processingID: return "Scheduled long run"
        case "ring connected", "restored link": return "Ring connected"
        case "health steps": return "Step update"
        default: return reason
        }
    }

    /// The same analysis the home screen runs on load, minus the UI.
    private static func summarize() async -> Summary? {
        let analysis = WorkCoordinator.shared.newAnalysis()
        await WorkGate.shared.acquire()
        let previous = SummaryCache.load()
        let summary: Summary = await withCheckedContinuation { completion in
            DispatchQueue.global(qos: .utility).async {
                completion.resume(returning: analysis.perform {
                    let base = Core.base()
                    #if TORCH
                    return base.error == nil && !analysis.isCancelled
                        ? Core.withModels(base, previous: previous) : base
                    #else
                    _ = previous
                    return base
                    #endif
                })
            }
        }
        await WorkGate.shared.release()
        WorkCoordinator.shared.finishAnalysis(analysis)
        return analysis.isCancelled ? nil : summary
    }
}
