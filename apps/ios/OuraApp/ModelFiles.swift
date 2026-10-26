import Foundation

/// Finds Oura's on-device models in the app bundle by family, not by exact file name.
/// Oura ships several versions of each model (`cva_2_1_0`, `cva_2_1_5`, …) and which
/// ones a build bundles depends on what was decrypted and exported locally. Each
/// family names the version its input code was validated against; that one wins when
/// present, otherwise the newest bundled version with the same inputs is used. A
/// family with no usable file stays a soft skip for the caller.
enum ModelFiles {
    struct Found { let path: String; let name: String; let version: String }

    /// Every family the app knows how to run, with the version its inputs were
    /// validated against. Also drives the Insights list on the status screen.
    /// `oldest`…`newest` bound the versions whose forward() takes the same inputs as
    /// the validated one. AAD 3.1.15 replaced the three scalar thresholds with a
    /// settings tensor, and CVA 1.x takes four inputs, so neither may stand in.
    struct Family { let family: String; let validated: String; let oldest: String; let newest: String; let title: String }
    static let known: [Family] = [
        Family(family: "sleepstaging", validated: "2_6_0", oldest: "2_6_0", newest: "2_6_0", title: "Sleep stages"),
        Family(family: "automatic_activity_detection", validated: "3_1_11", oldest: "3_1_0", newest: "3_1_12", title: "Workouts & activity"),
        Family(family: "steps_motion_decoder", validated: "2_0_0", oldest: "2_0_0", newest: "2_999_0", title: "Step motion"),
        Family(family: "cva", validated: "2_1_0", oldest: "2_0_0", newest: "2_999_0", title: "Cardiovascular age"),
        Family(family: "illness_detection", validated: "0_5_1", oldest: "0_5_0", newest: "0_5_999", title: "Symptom radar"),
    ]

    /// The validated version when bundled, else the newest compatible one.
    static func find(_ family: String) -> Found? {
        guard let spec = known.first(where: { $0.family == family }) else { return nil }
        let lo = versionKey(spec.oldest), hi = versionKey(spec.newest)
        let ok = bundled(family).filter {
            let v = versionKey($0.version)
            return !v.lexicographicallyPrecedes(lo) && !hi.lexicographicallyPrecedes(v)
        }
        return ok.first { $0.version == spec.validated } ?? ok.first
    }

    /// Bundled versions of one family, newest first.
    static func bundled(_ family: String) -> [Found] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ptl", subdirectory: nil) else { return [] }
        let prefix = family + "_"
        return urls.compactMap { url -> Found? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix) else { return nil }
            let version = String(name.dropFirst(prefix.count))
            // `cva_calibrator_1_3_0` shares the `cva_` prefix: a version is digits only.
            guard !version.isEmpty, version.split(separator: "_").allSatisfy({ Int($0) != nil })
            else { return nil }
            return Found(path: url.path, name: name, version: version)
        }
        .sorted { versionKey($1.version).lexicographicallyPrecedes(versionKey($0.version)) }
    }

    private static func versionKey(_ v: String) -> [Int] { v.split(separator: "_").compactMap { Int($0) } }

    /// "2_1_5" → "2.1.5", for display.
    static func display(_ version: String) -> String { version.replacingOccurrences(of: "_", with: ".") }
}
