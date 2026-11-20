import Foundation

/// Callsign rank earned from the total number of successful BBS calls (`AppPreferences.totalCalls`).
/// Mirrors the Windows client's `Services/EliteRank.cs` — same thresholds, same names.
///
/// Earlier history isn't counted: only a last-call time was ever stored, so the counter starts at 0
/// and every successful connect adds one (`recordSuccessfulCall`, called from `TerminalViewModel`).
/// Shown on the boot screen's RANK line and by the command line's `whoami` and `rank`.
enum EliteRank {
    /// Every rank, lowest first, with the calls it takes.
    static let all: [(minCalls: Int, name: String)] = [
        (0, "LAMER"),
        (5, "USER"),
        (20, "HACKER"),
        (50, "ELITE"),
        (150, "SYSOP"),
    ]

    /// The rank earned with `calls` successful connections.
    static func name(for calls: Int) -> String {
        all.last { calls >= $0.minCalls }?.name ?? all[0].name
    }

    /// The next rank and the total calls it needs, or nil at the top rank.
    static func next(for calls: Int) -> (name: String, calls: Int)? {
        for rank in all where rank.minCalls > calls {
            return (rank.name, rank.minCalls)
        }
        return nil
    }

    /// Successful BBS connections so far.
    static var totalCalls: Int {
        UserDefaults.standard.integer(forKey: AppPreferences.totalCalls)
    }

    /// Every successful BBS connection counts toward the rank.
    /// Added to the count as it stands now, under the cross-process lock: every BBS window is an instance of its own
    /// and counts its calls too (PORT_TO_MAC_LINUX §12.57).
    static func recordSuccessfulCall() {
        AppDataLock.updateDefaults { defaults in
            defaults.set(defaults.integer(forKey: AppPreferences.totalCalls) + 1, forKey: AppPreferences.totalCalls)
        }
    }

    /// "HACKER  (23 calls)" — the boot screen's RANK value and the `rank` command's first line.
    static func summary(for calls: Int) -> String {
        "\(name(for: calls))  (\(calls) call\(calls == 1 ? "" : "s"))"
    }
}
