import Foundation

/// One board's line in the call log.
struct BoardCallStats: Codable {
    var name: String = ""
    var address: String = ""
    var firstCall: Date = Date()
    var lastCall: Date = Date()
    var calls: Int = 0
    var secondsOnline: Double = 0
    var bytesReceived: Int64 = 0
    var bytesSent: Int64 = 0
}

/// The call log: calls, time online and data per board, keyed by the board's id. Kept in its own file
/// (callstats.json in Application Support/TERMinator) rather than on the phonebook entry, because the phonebook is
/// rewritten by edits and imports, and exported without extra fields — any of which would wipe or lose stats.
/// A call starts when the connection succeeds and ends when the session disconnects. Same data as the Windows and
/// Linux clients.
///
/// Each BBS window is an instance of the app of its own, all sharing the file (PORT_TO_MAC_LINUX §12.57), so a call's
/// start and end are applied to the log as it is on disk at that moment (under `AppDataLock`), and reading the log picks
/// up what other windows recorded.
final class CallStatsService {
    static let shared = CallStatsService()

    private let fileURL: URL
    private var stats: [String: BoardCallStats] = [:]

    /// The call in progress, if any: which board, and when it connected.
    private var activeId: String?
    private var activeStart = Date()
    /// When the file was last read or written here: a different stamp on disk means another instance wrote it.
    private var stamp: Date?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("TERMinator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("callstats.json")
        load()
    }

    func get(_ id: String) -> BoardCallStats? {
        reloadIfChanged()
        return stats[id]
    }

    var all: [BoardCallStats] {
        reloadIfChanged()
        return Array(stats.values)
    }

    private func reloadIfChanged() {
        guard AppDataLock.stamp(fileURL) != stamp else { return }
        AppDataLock.withLock {
            load()
        }
    }

    /// A call to a board just connected.
    func beginCall(id: String, name: String, address: String) {
        // A call that was never closed (shouldn't happen) keeps its time but no byte counts
        endCall(bytesSent: 0, bytesReceived: 0)

        AppDataLock.withLock {
            load()
            let now = Date()
            var entry = stats[id] ?? BoardCallStats(firstCall: now)
            entry.name = name
            entry.address = address
            entry.lastCall = now
            entry.calls += 1
            stats[id] = entry

            activeId = id
            activeStart = now
            save()
        }
    }

    /// The call in progress ended; adds its time online and data. Does nothing if no call is open.
    func endCall(bytesSent: Int64, bytesReceived: Int64) {
        guard let id = activeId else { return }
        AppDataLock.withLock {
            load()
            if var entry = stats[id] {
                entry.secondsOnline += max(0, Date().timeIntervalSince(activeStart))
                entry.bytesSent += max(0, bytesSent)
                entry.bytesReceived += max(0, bytesReceived)
                stats[id] = entry
            }
            activeId = nil
            save()
        }
    }

    /// One line for the phonebook: "12 calls · 3h 12m online · first … · last … · ↓ 1.2 MB ↑ 45.0 KB".
    func describe(_ id: String) -> String {
        reloadIfChanged()
        guard let entry = stats[id], entry.calls > 0 else { return "never called" }
        return "\(entry.calls) call\(entry.calls == 1 ? "" : "s") \u{00B7} \(Self.formatDuration(entry.secondsOnline)) online \u{00B7} "
            + "first \(Self.dayFormatter.string(from: entry.firstCall)) \u{00B7} last \(Self.minuteFormatter.string(from: entry.lastCall)) \u{00B7} "
            + "\u{2193} \(Self.formatBytes(entry.bytesReceived))  \u{2191} \(Self.formatBytes(entry.bytesSent))"
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours >= 1 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes >= 1 {
            return String(format: "%dm %02ds", minutes, secs)
        }
        return "\(secs)s"
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if bytes >= 1024 * 1024 * 1024 { return String(format: "%.1f GB", value / (1024 * 1024 * 1024)) }
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", value / (1024 * 1024)) }
        if bytes >= 1024 { return String(format: "%.1f KB", value / 1024) }
        return "\(bytes) B"
    }

    /// "yyyy-MM-dd HH:mm", as the other clients print it.
    static let minuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Reads the file. Callers other than init hold `AppDataLock`.
    private func load() {
        stamp = AppDataLock.stamp(fileURL)
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        stats = (try? decoder.decode([String: BoardCallStats].self, from: data)) ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stats) else { return }
        // The log is a nicety; never let a locked or full disk interrupt a call
        try? data.write(to: fileURL, options: .atomic)
        stamp = AppDataLock.stamp(fileURL)
    }
}
