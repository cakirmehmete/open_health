import Foundation

/// Seconds offloaded from the WHOOP strap, one append-only file per UTC day of
/// fixed 28-byte records. The strap may reclaim history once we acknowledge it,
/// so `append` returns only after the bytes are synced to disk. Files use the
/// default protection (readable after first unlock), so background drains work
/// while the phone is locked.
final class WhoopStore: @unchecked Sendable {
    static let shared = WhoopStore()
    /// Raw seconds older than this are deleted; Health keeps the derived samples.
    static let retentionDays = 45
    private static let newestKey = "whoop.store.newest"

    private let lock = NSLock()
    private let dir: URL

    init(directory: URL? = nil) {
        dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whoop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Unix time of the newest stored second, 0 when empty.
    var newest: UInt32 {
        UInt32(UserDefaults.standard.integer(forKey: Self.newestKey))
    }

    func append(_ samples: [WhoopSample]) throws {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let byDay = Dictionary(grouping: samples) { $0.unix / 86_400 }
        for (day, rows) in byDay {
            let url = file(day)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(rows.flatMap { $0.encoded() }))
            try handle.synchronize()
        }
        // Ignore far-future timestamps from a strap whose clock was wrong.
        let plausible = samples.map(\.unix).filter { TimeInterval($0) < Date().timeIntervalSince1970 + 3600 }
        if let latest = plausible.max(), latest > newest {
            UserDefaults.standard.set(Int(latest), forKey: Self.newestKey)
        }
    }

    /// Stored seconds in `[from, to)`, sorted, one per timestamp (a chunk the strap
    /// resent after a dropped acknowledgement appears twice on disk).
    func samples(from: UInt32, to: UInt32) -> [WhoopSample] {
        guard to > from else { return [] }
        lock.lock(); defer { lock.unlock() }
        var out: [UInt32: WhoopSample] = [:]
        for day in (from / 86_400)...((to - 1) / 86_400) {
            guard let data = try? Data(contentsOf: file(day)) else { continue }
            let bytes = [UInt8](data)
            var offset = 0
            while let s = WhoopSample(stored: bytes, at: offset) {
                if s.unix >= from && s.unix < to { out[s.unix] = s }
                offset += WhoopSample.storedLength
            }
        }
        return out.keys.sorted().compactMap { out[$0] }
    }

    func prune(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = UInt32(now.timeIntervalSince1970) / 86_400 - UInt32(Self.retentionDays)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasSuffix(".bin") {
            if let day = UInt32(name.dropLast(4)), day < cutoff {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    private func file(_ day: UInt32) -> URL { dir.appendingPathComponent("\(day).bin") }
}
