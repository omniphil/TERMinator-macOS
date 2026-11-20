import Foundation

/// The modem speeds offered for speed emulation: real line rates, each with the standard that carried it. 0 is full
/// speed. Emulation meters at bps / 10 characters a second (8 data bits plus start and stop bits), which is the raw
/// line. 57600 and 115200 are deliberately absent: those were serial-port (DTE) settings, never line rates. "56k" runs
/// at 50000, since V.90 downloads topped out at 53.3k and usually connected in the 40-50k range.
/// Same list and wording as the Windows and Linux clients.
enum ModemSpeeds {
    static let rates: [Int] = [0, 300, 1200, 2400, 9600, 14400, 19200, 28800, 33600, 50000]

    /// What the menu, Preferences and the command line call a speed.
    static func label(_ bps: Int) -> String {
        switch bps {
        case ...0: return "Off (full speed)"
        case 300: return "300 bps (Bell 103)"
        case 1200: return "1200 bps (V.22)"
        case 2400: return "2400 bps (V.22bis)"
        case 9600: return "9600 bps (V.32)"
        case 14400: return "14.4k (V.32bis)"
        case 19200: return "19.2k (V.32terbo)"
        case 28800: return "28.8k (V.34)"
        case 33600: return "33.6k (V.34+)"
        case 50000: return "56k (V.90)"
        default: return "\(bps) bps"
        }
    }

    /// Short names for Tab completion in the command line ("baud").
    static let shortNames = ["off", "300", "1200", "2400", "9600", "14.4k", "19.2k", "28.8k", "33.6k", "56k"]

    /// Reads a speed typed in the command line: "off" / "0", a listed rate ("2400"), a k form ("14.4k", "56k"), or
    /// "56000" / "57600" for the 56k entry. Only listed speeds are accepted; nil otherwise.
    static func parse(_ text: String) -> Int? {
        let arg = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "bps", with: "")
            .trimmingCharacters(in: .whitespaces)
        if arg == "off" || arg == "0" {
            return 0
        }

        let value: Double
        if arg.hasSuffix("k") {
            guard let number = Double(arg.dropLast()) else { return nil }
            value = number * 1000
        } else {
            guard !arg.isEmpty, arg.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Double(arg) else { return nil }
            value = number
        }

        var requested = Int(value.rounded())
        if requested == 56000 || requested == 57600 {
            requested = 50000
        }
        guard let index = rates.firstIndex(of: requested), index > 0 else { return nil }
        return requested
    }

    /// A stored speed that's no longer listed (57600 / 115200 from before the list followed the real standards)
    /// becomes the nearest listed one, so the menu and Preferences always show a checked choice.
    static func normalize(_ bps: Int) -> Int {
        if bps <= 0 || rates.contains(bps) {
            return max(0, bps)
        }
        return rates.filter { $0 > 0 }.min(by: { abs($0 - bps) < abs($1 - bps) }) ?? 0
    }
}
