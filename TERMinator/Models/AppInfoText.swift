import Foundation

/// Version, changelog and credits text, shared by the About box, the Changelog window and
/// the command line's `about` / `changelog` commands so the copies never drift apart.
/// Mirrors the Windows client's `Services/AppInfoText.cs`.
enum AppInfo {
    /// Version straight from the bundle. The About box and the window title both read this:
    /// they were hardcoded separately once and had already drifted apart.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    /// Newest first, mirroring the Windows client's What's New list. macOS folds
    /// the CRT/ZMODEM work into 1.0.3, where Windows ships it as its 1.0.4.
    /// Add a new entry when the version in Info.plist is bumped, not before.
    ///
    /// There is NO 1.0.5 — the number is skipped on purpose. Windows shipped a 1.0.5
    /// that macOS had no counterpart for, and the release that brought the two version
    /// lines back into step (first listed as 1.0.6) is now 1.1.0, shared by all three
    /// desktop clients. Do not "fill the gap" later.
    static let changelog: [(version: String, changes: [String])] = [
        ("1.1.7", ["TAP+ improvements",
                   "Connection time out retries",
                   "SSH lockup fix"]),
        // Same line as Windows 1.1.6 (PORT_TO_MAC_LINUX.md "2026-10-20 — 1.1.6"): a Rainwire board's menus drawn here.
        ("1.1.6", ["Rainwire screen engine support",
                   "Rainwire gadget engine support",
                   "TRACE performance upgrades"]),
        // PETSCII belongs here rather than in a 1.0.5: the cterm.c migration landed
        // 2026-09-04, after 1.0.4 had shipped, and macOS has no 1.0.5 at all.
        // No TelnetS line: macOS TelnetS uses Apple's TLS, which already accepts the
        // misconfigured chains the Windows/Linux cryptlib fix was for.
        // Same lines as Windows 1.1.1. The SyncTERM APC port (TERMinator-Windows/PORT_SYNCDOOM_TO_MAC_LINUX.md) is what
        // makes them true here.
        // Same line as Windows 1.1.5 (PORT_TO_MAC_LINUX.md §12.59): xterm mouse reporting and Rainwire's client-drawn
        // windows.
        ("1.1.5", ["Rainwire BBS support",
                   "ZMODEM 8K optimizations",
                   "Added Check for Updates in Help menu",
                   "Rainwire drag & drop file transfers",
                   "Rainwire multi-window support"]),
        // Same lines as Windows 1.1.4. The Ed25519 line is only true once libcl.a is rebuilt on
        // the Mac with the ssh-ed25519 host-key patch (scripts/build-cryptlib-macos.sh).
        // "Multi-window/multi-BBS" as on Windows (PORT_TO_MAC_LINUX.md §12.57): each BBS in an instance of its own.
        ("1.1.4", ["Multi-window/multi-BBS support",
                   "Super ZMODEM 8K support",
                   "Ed25519 SSH key support"]),
        // Same lines as Windows 1.1.3 (PORT_TO_MAC_LINUX.md §12.45-12.49).
        ("1.1.3", ["TRACE - GPU support",
                   "TRACE - gamepad support",
                   "TRACE - mouse support"]),
        // Same line as Windows 1.1.2 (PORT_TO_MAC_LINUX.md §12.20).
        ("1.1.2", ["TRACE support (TERMinator Render and Compute Engine)",
                   "Variable connection timeout"]),
        ("1.1.1", ["JPEG XL graphics for BBS doors",
                   "BBS door sound and music",
                   "Sixel performance improvements"]),
        ("1.1.0", ["Layout overhaul",
                   "Command line mode (Elite)",
                   "Side-by-side layout option",
                   "Proper 4:3 aspect ratio",
                   "Phonebook import / export",
                   "In-app help (F1)",
                   "Save Screenshot, and the SSH debug log on demand",
                   "Terminal right-click menu",
                   "Per-connection BBS status line",
                   // macOS-only additions: Windows shipped PETSCII in its 1.0.5 (which
                   // macOS skipped) and never had the Zoom menu items.
                   "Commodore PETSCII support (C64 / C128 screen modes)",
                   "Removed the Zoom menu items, which never did anything"]),
        ("1.0.4", ["XMODEM / YMODEM file transfers",
                   "Windows secure sockets support (WebSocket / Secure WebSocket)",
                   "Raw connection type"]),
        ("1.0.3", ["CRT and scanline effects",
                   "ZMODEM fixes/improvements",
                   "Sixel screen clearing for Mystic"]),
        ("1.0.2", ["132x60 screen modes added",
                   "True color support",
                   "Better Sixel support"]),
        ("1.0.1", ["ZMODEM batch uploads"]),
        ("1.0.0", ["Dynamic font switching",
                   "Added 5 Amiga fonts",
                   "Phonebook alphabetical sort"]),
    ]

    /// The changelog as plain lines, Windows style: version headers start with "v",
    /// bullets with "• ", and an empty line separates versions.
    static var changelogLines: [String] {
        var lines: [String] = []
        for (index, entry) in changelog.enumerated() {
            if index > 0 { lines.append("") }
            lines.append("v\(entry.version)")
            for change in entry.changes {
                lines.append("\u{2022} \(change)")
            }
        }
        return lines
    }

    /// One run of the credits text; a run with a URL is a clickable link in the About box.
    struct CreditsRun {
        let text: String
        let url: URL?
    }

    /// The credits, as runs of text. Same wording as Windows apart from the platform name
    /// and repository.
    static let credits: [CreditsRun] = [
        CreditsRun(text: "Based on SyncTERM, we would not exist without the legendary work of\n"
                       + "SyncTERM, so hats off to the SyncTERM folks!\n\n"
                       + "macOS version by JSONBourne 2026\n"
                       + "JSONBourne Innovations\n", url: nil),
        CreditsRun(text: "jsonbourneinnovations@gmail.com", url: URL(string: "mailto:jsonbourneinnovations@gmail.com")),
        CreditsRun(text: "\n", url: nil),
        CreditsRun(text: "deadmodemsociety.com", url: URL(string: "https://deadmodemsociety.com")),
        CreditsRun(text: "\n\n"
                       + "Special thx to aNACHRONiST (aNSt) for the artwork and testing!\n"
                       + "He may be reached at: ", url: nil),
        CreditsRun(text: "aNSt@absinthebbs.net", url: URL(string: "mailto:aNSt@absinthebbs.net")),
        CreditsRun(text: " for collaborations and commissions\n\n"
                       + "This application is open source and licensed under the GNU GPL v2.\n"
                       + "GitHub: ", url: nil),
        CreditsRun(text: "github.com/omniphil/TERMinator-macOS", url: URL(string: "https://github.com/omniphil/TERMinator-macOS")),
    ]

    /// The credits as plain text lines (links shown as their text). Used by the command line's `about`.
    static var creditsLines: [String] {
        credits.map { $0.text }.joined().components(separatedBy: "\n")
    }
}
