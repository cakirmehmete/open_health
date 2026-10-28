import Foundation
import UserNotifications

/// "You may be getting sick": a local notification when Oura's illness model (Symptom
/// Radar, IllnessModel.swift) moves a day to MINOR or MAJOR signs. It reads only the
/// model's own decision; nothing here scores or thresholds the biomarkers itself.
///
/// One alert per day and level: the first MINOR/MAJOR for a date notifies, an
/// escalation from MINOR to MAJOR on the same date notifies again, and re-running the
/// same pass (foreground, background, cache) stays quiet. Runs wherever a summary is
/// saved, so the background sync (ring connect, BGTasks) alerts without opening the app.
/// Twin of the web dashboard's notifyIllness().
enum IllnessAlert {
    private static let lastKey = "illness-alert.last"   // "yyyy-mm-dd|rank"
    private static let askedKey = "illness-alert.asked"

    private static func rank(_ light: String) -> Int {
        switch light { case "MAJOR_SIGNS": return 2; case "MINOR_SIGNS": return 1; default: return 0 }
    }

    /// Show the alert as a banner even while the app is open (iOS hides it otherwise).
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list, .sound])
        }
    }
    private static let presenter = Presenter()
    static func install() { UNUserNotificationCenter.current().delegate = presenter }

    /// Ask once for alert permission, from the foreground UI (a background launch
    /// can't show the prompt). Only builds that can run the model ask.
    static func requestAuthorization() {
        #if TORCH
        guard ModelFiles.find("illness_detection") != nil,
              !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            UserDefaults.standard.set(true, forKey: askedKey)
            dlog("illness", "notification permission granted=\(granted) error=\(error.map { "\($0)" } ?? "none")")
        }
        #endif
    }

    static func check(_ summary: Summary) {
        guard let radar = summary.symptomRadar else { return }
        let level = rank(radar.trafficLight)
        guard level > 0 else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.string(forKey: lastKey)?.split(separator: "|"), last.count == 2,
           last[0] == radar.date, let shown = Int(last[1]), shown >= level { return }
        // Only alert on the latest night: an old result restored from cache is not news.
        if let newest = summary.nights.compactMap({ summary.wakeYmd($0) }).max(), radar.date < newest { return }

        let flagged = radar.biomarkers.filter(\.indicatesSymptoms).map { label($0) }
        let content = UNMutableNotificationContent()
        content.title = level == 2 ? "Major signs of illness" : "Minor signs of illness"
        var body = level == 2 ? "Your body may be fighting something." : "A few biometrics are outside your usual range."
        if !flagged.isEmpty { body += " " + flagged.joined(separator: ", ") + "." }
        body += " Consider an easy day."
        content.body = body
        content.sound = .default
        content.threadIdentifier = "symptom-radar"
        let request = UNNotificationRequest(identifier: "symptom-radar-\(radar.date)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { dlog("illness", "alert failed: \(error)"); return }
            defaults.set("\(radar.date)|\(level)", forKey: lastKey)
            dlog("illness", "alert date=\(radar.date) level=\(radar.trafficLight) flagged=\(flagged.count)")
        }
    }

    private static func label(_ b: IllnessBiomarker) -> String {
        let name = ["AverageBreath": "Breathing rate", "LowestHeartRate": "Lowest heart rate",
                    "AverageHrv": "HRV", "TemperatureDeviation": "Body temperature"][b.type] ?? b.type
        return "\(name) \(b.reason == "DECREASED" ? "down" : "up")"
    }
}
