import BackgroundTasks
import UIKit

/// Keeps ring → Apple Health flowing without the app on screen, so a reader such
/// as Bevel sees fresh data. iOS decides when these tasks run (more often for apps
/// it sees used, never after the app is swiped away from the switcher); each run
/// drains the ring, rebuilds the summary, and exports it to Health.
///
/// - refresh: short, frequent slots. Enough for an incremental drain of an hour
///   or two of history; a longer drain checkpoints and resumes next time.
/// - processing: longer slots, typically while the phone sits idle overnight.
///
/// Health refuses writes while the phone is locked. A run that syncs the ring but
/// can't export leaves the fingerprint unsaved, so the next unlocked run retries.
@MainActor
enum BackgroundSync {
    static let refreshID = "md.thomas.openoura.refresh"
    static let processingID = "md.thomas.openoura.sync"
    /// Ask to run about this often. iOS treats it as a floor, not a schedule.
    static let interval: TimeInterval = 45 * 60

    /// Registration must finish before the app finishes launching.
    static func register() {
        for id in [refreshID, processingID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
                MainActor.assumeIsolated { handle(task) }
            }
        }
    }

    static func schedule() {
        guard Keychain.loadKey() != nil else { return }
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
        let report = await RingSync.shared.syncAutomaticallyIfNeeded()
        dlog("bg", "ring sync \(report == nil ? "skipped or failed" : "done") status=\(RingSync.shared.status)")
        guard !Task.isCancelled else { return false }

        guard let summary = await summarize(), summary.error == nil else {
            dlog("bg", "summary unavailable")
            return false
        }
        SummaryCache.save(summary)
        let exported = HealthExport.shared.enabled ? await HealthExport.shared.pushAndWait(summary) : true
        dlog("bg", "end \(reason) exported=\(exported) duration=\(Int(Date().timeIntervalSince(started)))s")
        return exported
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
