import Foundation

enum DayAnalysisKind: String, CaseIterable {
    case sleep = "Sleep", activity = "Activity"
}

struct DayAnalysisRequest: Equatable {
    let day: String
    let kind: DayAnalysisKind
}

/// Last successfully rendered summary. It is display-only: the SQLite store remains
/// the source of truth and a fresh summary always replaces this after launch. Keeping
/// it out of UserDefaults avoids loading a potentially large signal payload there.
enum SummaryCache {
    private static let queue = DispatchQueue(label: "md.thomas.openoura.summary-cache", qos: .utility)
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("summary-cache.json")
    }

    private struct CachedSummary: Codable {
        var summary: Summary
        var workouts: [WorkoutSession]
        var illness: IllnessResult?
        var stress: DaytimeStress?
    }
    static func load() -> Summary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let cached = try? JSONDecoder().decode(CachedSummary.self, from: data), cached.summary.error == nil {
            var result = cached.summary
            result.workouts = cached.workouts; result.illness = cached.illness; result.stress = cached.stress
            return result
        }
        guard let legacy = try? JSONDecoder().decode(Summary.self, from: data), legacy.error == nil else { return nil }
        return legacy
    }

    static func save(_ summary: Summary) {
        guard summary.error == nil else { return }
        IllnessAlert.check(summary)
        queue.async {
            guard let data = try? JSONEncoder().encode(CachedSummary(summary: summary, workouts: summary.workouts, illness: summary.illness, stress: summary.stress)) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }
}

enum Core {
    /// Fast, model-free summary (vitals, activity ridges, device) straight from the
    /// shared-core JSON — safe to compute on a background queue and show immediately.
    static func base() -> Summary {
        let path = DB.readPath()   // synced DB if present, else the bundled seed
        // the phone's actual UTC offset, so night labels / sleep windows / digest
        // timing match the wearer's local clock — not a hardcoded constant. The whole
        // stack (web --tz-offset, the Python model runners, this FFI) takes whole
        // hours, so round to the nearest hour (best representable value for the rare
        // sub-hour zones like IST +5:30).
        let secs = TimeZone.current.secondsFromGMT()
        let tzOffset = Int64((Double(secs) / 3600).rounded())
        let json = summaryJson(dbPath: path, tzOffset: tzOffset)
        guard let data = json.data(using: .utf8) else { return Summary(error: "decode failed") }
        do { return try JSONDecoder().decode(Summary.self, from: data) }
        catch {
            dlog("core", "summary decode failed: \(error) json=\(json.prefix(300))")
            return Summary(error: "decode failed")
        }
    }

    #if TORCH
    /// Launch and sync only fill the latest night's missing analysis. Historical
    /// results stay visible, and older missing nights are refreshed on demand.
    static func automaticSleepPlan(nights: [NightRow], previous: Summary?, revalidateLatest: Bool = false,
                                   profile: Profile? = nil) -> (saved: [String: [Int]], pending: [NightRow]) {
        let compatiblePrevious = SleepStaging.demographics(previous?.profile) == SleepStaging.demographics(profile)
            ? previous : nil
        var saved: [String: [Int]] = [:]
        for night in nights {
            guard night.start_ds != nil else { continue }
            if let old = compatiblePrevious?.nights.first(where: {
                $0.start_ds == night.start_ds && $0.end_ds == night.end_ds
                    && $0.ymd == night.ymd && $0.start == night.start && $0.end == night.end
                    && $0.start_unix == night.start_unix && $0.end_unix == night.end_unix
            }), old.staging_source == "nssa", let stages = old.hypnogram, !stages.isEmpty {
                saved[night.stagingKey] = stages
            }
        }
        // Pick the night you woke from most recently (absolute end time, falling
        // back to wake date, then list order). Do not backfill an older missing
        // night when the newest one already has a result.
        let latest = nights.enumerated().max { lhs, rhs in
            let l = lhs.element, r = rhs.element
            if let le = l.end_unix, let re = r.end_unix, le != re { return le < re }
            let lw = l.wake_ymd ?? l.ymd ?? "", rw = r.wake_ymd ?? r.ymd ?? ""
            if lw != rw { return lw < rw }
            return lhs.offset > rhs.offset
        }?.element
        guard let latest, latest.start_ds != nil,
              latest.end_ds != nil, revalidateLatest || saved[latest.stagingKey] == nil else { return (saved, []) }
        return (saved, [latest])
    }

    /// Refresh one report without running unrelated models or discarding other days.
    static func refreshAnalysis(_ previous: Summary, request: DayAnalysisRequest,
                                progress: @escaping @Sendable (String) -> Void = { _ in }) -> (summary: Summary, error: String?) {
        defer { oura_torch_release() }
        let base = Core.base()
        guard base.error == nil else { return (previous, "Couldn’t read saved data. Try again.") }
        do {
            let events = try EventStore.decodedEvents(dbPath: DB.readPath())
            let clock = EventStore.RingClock(events: events)
            try events.validate()
            try AnalysisRun.check()
            var updated = previous
            switch request.kind {
            case .sleep:
                guard let night = base.night(forDay: request.day), let start = night.start_ds else {
                    return (previous, "No sleep data is saved for this day.")
                }
                let result = SleepStaging.run(nights: [night], events: events, clock: clock,
                                             profile: base.profile, force: true, pruneCache: false, progress: progress)
                if let error = result.error { throw AnalysisRefreshFailure(error) }
                guard let stages = result.staged[night.stagingKey], !stages.isEmpty else {
                    return (previous, "Not enough saved sleep data to refresh this night.")
                }
                let previousStart = previous.night(forDay: request.day)?.start_ds
                let rawStart = night.raw_start_ds
                if let index = updated.nights.firstIndex(where: {
                    $0.start_ds == start
                        || (previousStart != nil && $0.start_ds == previousStart)
                        || (rawStart != nil && $0.raw_start_ds == rawStart)
                }) {
                    updated.nights[index] = night
                } else { updated.nights.append(night) }
                applySleepStages(result.staged, to: &updated)
            case .activity:
                guard base.activity_profile[request.day] != nil else {
                    return (previous, "No activity data is saved for this day.")
                }
                let result = ActivityModel.run(profile: base.profile, events: events, clock: clock,
                                               onlyDay: request.day, force: true, progress: progress)
                if let error = result.error { throw AnalysisRefreshFailure(error) }
                updated.workouts.removeAll { $0.dayLabel == request.day }
                updated.workouts.append(contentsOf: result.sessions)
                updated.workouts.sort { $0.start < $1.start }
                // The aggregate message names only the first failed day; a successful
                // rerun of that day means the list is stale either way.
                updated.modelErrors.removeAll { $0.hasPrefix("Activity analysis failed for") }
            }
            try events.validate()
            try AnalysisRun.check()
            return (updated, nil)
        } catch {
            if AnalysisRun.cancelled { return (previous, "Refresh paused. Keep the app open and try again.") }
            dlog("models", "refresh day=\(request.day) kind=\(request.kind.rawValue) failed: \(error)")
            return (previous, "Couldn’t refresh \(request.kind.rawValue.lowercased()) analysis. Your previous results are still available. See Help & diagnostics for details.")
        }
    }

    private struct AnalysisRefreshFailure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    /// The slow part: run the three on-device torch models and fold their results into
    /// the summary. Call off the main thread (see RootView.load); never on launch.
    ///
    /// Models share one LibTorch runtime, so they run one after another (TorchBridge
    /// also serializes `forward()`). Concurrent inference raced the interpreter and
    /// peaked RAM on hiking-heavy histories. Each reports a per-model error for
    /// genuine failures; those surface in `modelErrors`.
    static func withModels(_ base: Summary, previous: Summary?,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) -> Summary {
        var s = base
        let profile = base.profile
        // Loaded modules are only reused within one pass; free them before the app
        // can be suspended with them resident (see TorchBridge.mm).
        defer { oura_torch_release() }

        let validPrevious = previous?.analysis_version == ModelCacheStore.version ? previous : nil
        var cva: CvaModel.Result?
        var workouts: [WorkoutSession] = []
        var illness: IllnessResult?
        var sleepErr: String?, cvaErr: String?, actErr: String?, illErr: String?, breathErr: String?, stressErr: String?
        var breathing: [String: Breathing] = [:]
        var nightBreath: [String: NightBreathing.Result] = [:]
        var stress: DaytimeStress?
        var steps: [String: [Double]] = [:]
        var stepsErr: String?

        var stageStarted = ProcessInfo.processInfo.systemUptime
        func stageFinished(_ stage: String) {
            dlog("models", "stage=\(stage) duration=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - stageStarted))s")
            stageStarted = ProcessInfo.processInfo.systemUptime
            memLog(stage)
        }

        // One store digest per pass (a full-table scan), shared by the models. When
        // no night is pending and the store is unchanged since the last complete
        // pass, every event model is a cache hit: skip the event read and the
        // RingClock rebuild, which cost ~15 s on every foreground with nothing new.
        progress("Reading ring data")
        let storeDigest = EventStore.Events(path: DB.readPath()).digest()
        let sleepPlan = automaticSleepPlan(nights: base.nights, previous: validPrevious,
                                           revalidateLatest: storeDigest == nil || validPrevious?.analysis_digest != storeDigest,
                                           profile: profile)
        var staged = SleepStaging.cachedStages(nights: base.nights, profile: profile)
        staged.merge(sleepPlan.saved) { _, fresh in fresh }
        var sleepPending = sleepPlan.pending
        for night in base.nights.prefix(7) {
            guard night.start_ds != nil, night.end_ds != nil, night.hasSignals,
                  staged[night.stagingKey] == nil,
                  !sleepPending.contains(where: { $0.stagingKey == night.stagingKey }) else { continue }
            sleepPending.append(night)
        }
        if sleepPending.isEmpty,
           let rAct = ActivityModel.cachedRun(profile: profile, storeDigest: storeDigest),
           let rIll = IllnessModel.cachedRun(profile: profile, storeDigest: storeDigest),
           let rStress = StressModel.cachedRun(storeDigest: storeDigest) {
            s.analysis_digest = storeDigest
            s.analysis_version = ModelCacheStore.version
            workouts = rAct.sessions; actErr = rAct.error
            illness = rIll.result; illErr = rIll.error
            breathing = BreathingModel.cached(nights: base.nights)
            nightBreath = NightBreathing.cached(nights: base.nights)
            stress = rStress.result; stressErr = rStress.error
            steps = StepCounter.cached()
            dlog("models", "store unchanged since the last complete pass; event read skipped")
            stageFinished("cached")
            if AnalysisRun.cancelled { return previous ?? base }
        } else {
            // One shared read: one failure point, one lock-contention window, and the
            // RingClock epoch recovery is paid once instead of once per model.
            var events = EventStore.Events(path: DB.readPath())
            var readErr: String?
            do {
                events = try EventStore.decodedEvents(dbPath: DB.readPath())
            } catch {
                readErr = "\(error)"
            }
            memLog("streaming events")
            stageStarted = ProcessInfo.processInfo.systemUptime

            if readErr == nil, !events.isEmpty {
                s.analysis_digest = storeDigest
                s.analysis_version = ModelCacheStore.version
                progress("Mapping ring clock")
                let clock = EventStore.RingClock(events: events)
                if events.error != nil || AnalysisRun.cancelled { return previous ?? base }
                let rSleep = sleepPending.isEmpty
                    ? (staged: [String: [Int]](), error: Optional<String>.none)
                    : SleepStaging.run(nights: sleepPending, events: events, clock: clock,
                                       profile: profile, pruneCache: false, progress: progress)
                staged.merge(rSleep.staged) { _, fresh in fresh }
                sleepErr = rSleep.error
                dlog("models", "sleep automatic saved=\(staged.count) pending=\(sleepPending.count)")
                stageFinished("sleep")
                if AnalysisRun.cancelled { return previous ?? base }
                let rAct = ActivityModel.run(profile: profile, events: events, clock: clock,
                                             knownDigest: storeDigest, progress: progress)
                workouts = rAct.sessions; actErr = rAct.error
                stageFinished("activity")
                if AnalysisRun.cancelled { return previous ?? base }
                progress("Analyzing breathing rate")
                let rBr = NightBreathing.run(nights: base.nights, events: events, clock: clock)
                nightBreath = rBr.results
                stageFinished("breathing-rate")
                if AnalysisRun.cancelled { return previous ?? base }
                progress("Analyzing symptom radar")
                let rIll = IllnessModel.run(profile: profile, events: events, clock: clock,
                                            breathByWake: NightBreathing.byWakeDate(nightBreath, nights: base.nights, summary: base),
                                            knownDigest: storeDigest)
                illness = rIll.result; illErr = rIll.error
                stageFinished("illness")
                if AnalysisRun.cancelled { return previous ?? base }
                progress("Analyzing breathing")
                let rBreath = BreathingModel.run(nights: base.nights, events: events, clock: clock)
                breathing = rBreath.results; breathErr = rBreath.error
                stageFinished("breathing")
                if AnalysisRun.cancelled { return previous ?? base }
                progress("Analyzing daytime stress")
                let rStress = StressModel.run(events: events, clock: clock, knownDigest: storeDigest)
                stress = rStress.result; stressErr = rStress.error
                stageFinished("stress")
                if AnalysisRun.cancelled { return previous ?? base }
                if StepCounter.available {
                    progress("Counting steps")
                    let rSteps = StepCounter.run(events: events, clock: clock)
                    steps = rSteps.days; stepsErr = rSteps.error
                    stageFinished("steps")
                }
            } else if let readErr {
                // The shared read failed: every event-fed model is unavailable this
                // pass. Surface one error; the publish below falls back to `previous`.
                sleepErr = readErr; actErr = readErr; illErr = readErr; stressErr = readErr; stepsErr = readErr
            }
        }
        if AnalysisRun.cancelled { return previous ?? base }
        progress("Analyzing cardiovascular age")
        let rCva = CvaModel.run(sex: profile?.sex ?? "M", age: profile?.age ?? 30,
                                heightM: profile?.height_m ?? 1.78, weightKg: profile?.weight_kg ?? 75,
                                ringSize: profile?.ring_size ?? 10)
        cva = rCva.result; cvaErr = rCva.error
        stageFinished("cva")

        // fold SleepNet's hypnogram + stage breakdown into each night, keyed by the exact
        // bedtime start and absolute epoch so rebooted counters cannot collide.
        applySleepStages(staged, to: &s)
        for i in s.nights.indices {
            let key = s.nights[i].stagingKey
            let result = breathing[key] ?? previous?.nights.first(where: { $0.stagingKey == key })?.breathing
            s.nights[i].breathing = result
            // Oura's ecore nightly breathing rate replaces the ring's per-window median.
            if let r = nightBreath[key] {
                s.nights[i].breath_rate = (r.rate * 10).rounded() / 10
                s.nights[i].breath_rate_source = "ecore"
            }
        }
        if let cva {
            s.cardio = Cardio(vascular_age: cva.vascularAge, chronological_age: profile?.age ?? 30,
                              pwv_ms: cva.pwv, segments: cva.segments)
        } else if cvaErr != nil {
            s.cardio = previous?.cardio
        }
        // Per-day failures leave every other day's sessions valid; only a pass that
        // produced nothing (interrupted, model missing) falls back to the last result.
        s.workouts = (actErr == nil || !workouts.isEmpty) ? workouts : (previous?.workouts ?? workouts)
        s.illness = (illErr == nil || illness != nil) ? illness : previous?.illness
        s.stress = (stressErr == nil || stress != nil) ? stress : previous?.stress
        if StepCounter.available { StepCounter.apply(steps, to: &s) }
        var seen = Set<String>()
        s.modelErrors = [sleepErr, cvaErr, actErr, illErr, breathErr, stressErr, stepsErr].compactMap { $0 }
            .filter { seen.insert($0).inserted }
        for error in s.modelErrors { dlog("models", "failed: \(error)") }
        return s
    }

    private static func applySleepStages(_ staged: [String: [Int]], to s: inout Summary) {
        // First-epoch time of each night Oura's model staged. Its hypnograms are used
        // verbatim (oura-summary is_oura_staging); unstaged nights keep no stages.
        let meta = SleepStaging.cachedEntries(nights: s.nights, profile: s.profile)
        for i in s.nights.indices {
            guard s.nights[i].start_ds != nil, let stages = staged[s.nights[i].stagingKey], !stages.isEmpty else { continue }
            let entry = meta[s.nights[i].stagingKey]
            let source = "nssa"
            s.nights[i].stages = stages
            s.nights[i].stages_full = stages
            s.nights[i].staging_source = source
            s.nights[i].stages_5min = Sleep.isOuraStaging(source) ? Sleep.aggregate5Min(stages) : nil
            s.nights[i].stages_t0_unix = entry?.t0Unix
            s.nights[i].staging_complete = stages.allSatisfy { (1...4).contains($0) }
            s.nights[i].staging_coverage_pct = Double(stages.filter { (1...4).contains($0) }.count) / Double(stages.count) * 100
            let total = Double(stages.count)
            let pct = { (code: Int) in (Double(stages.filter { $0 == code }.count) / total * 100).rounded() }
            s.nights[i].deep_pct = pct(1); s.nights[i].light_pct = pct(2)
            s.nights[i].rem_pct = pct(3); s.nights[i].wake_pct = pct(4)
            let asleep = total - Double(stages.filter { $0 == 4 }.count)
            s.nights[i].efficiency = s.nights[i].stagingComplete ? (asleep / total * 100).rounded() : nil
            s.nights[i].autonomic = Sleep.autonomic(night: s.nights[i], stages: s.nights[i].analysisStages)
        }
    }
    #endif
}

