import Foundation

/// Phosphor tube color for the home screen and command line (View > Phosphor).
/// `Color` means no tint. Stored by raw value under `AppPreferences.phosphor`.
enum PhosphorMode: String, CaseIterable, Identifiable {
    case color = "Color"
    case green = "Green"
    case amber = "Amber"
    case white = "White"

    var id: String { rawValue }

    /// The tube color for the monochrome modes; nil for full color.
    /// The phosphor effect is luminance × this color, brightness × 1.2 (`ScreenEffectModifier`).
    var tintHex: String? {
        switch self {
        case .color: return nil
        case .green: return "#33FF66"
        case .amber: return "#FFB000"
        case .white: return "#EEF4FF"
        }
    }
}

/// UserDefaults keys and defaults for the settings added with the 1.1.0 home screen overhaul.
/// Mirrors the Windows client's `AppSettings` (stored camelCase in its settings.json).
///
/// Everything here is read through `@AppStorage(AppPreferences.<key>)` so a menu toggle, the
/// home screen and (later) the command line all see one value.
enum AppPreferences {
    /// Side-by-side home layout. False, but TRUE on a first run only (see `registerDefaults`):
    /// the flip happens in the first-run branch, not as the default, so upgraders keep stacked.
    static let homeSideBySide = "home_side_by_side"
    /// Boot screen on launch. Default true. Read by ContentView (`BootSequenceView`).
    static let showBootSequence = "show_boot_sequence"
    /// Idle screensaver. Default true. Read by `IdleWatcher` on every check.
    static let screensaverEnabled = "screensaver_enabled"
    /// `PhosphorMode` raw value. Default "Color". The console's `phosphor` command writes it; the
    /// tint on the home screen and the console reads it (`ScreenEffectModifier`).
    static let phosphor = "phosphor"
    /// Successful BBS connections, for the elite rank (`EliteRank`). Default 0. The boot screen's
    /// RANK line reads it and every successful connect adds 1 (`TerminalViewModel.connect`);
    /// the console's `whoami` / `rank` read it too.
    static let totalCalls = "total_calls"
    /// Modem speed emulation in bps (`ModemSpeeds.rates`); 0 = full speed. Default 0. Call > Modem Speed,
    /// Preferences and the console's `baud` write it; ContentView pushes it to the native bridge.
    static let emulatedBaud = "emulated_baud"
    /// The terminal status bar's modem front-panel lights. Default true.
    static let showModemLights = "show_modem_lights"
    /// IBM Model M key clicks while typing into a board or the command line. Default false.
    static let keyClicksEnabled = "key_clicks_enabled"
    /// Key click volume, 0-10. Default 3.
    static let keyClickVolume = "key_click_volume"
    /// Transfer > ZMODEM 8K Blocks (Windows `AppSettings.Zmodem8k`): uploads may grow to 8K
    /// subpackets ("Super ZMODEM 8K"). Default false. TransferManager pushes it to the native
    /// bridge at the start of every ZMODEM transfer.
    static let zmodem8k = "zmodem_8k"
    /// How long to wait for a BBS to answer before giving up, in seconds (Windows `AppSettings.ConnectionTimeoutSeconds`,
    /// PORT_TO_MAC_LINUX §12.27). Default 10; one of `connectionTimeoutChoices`. Read at connect time
    /// (`connectionTimeout`), so a change applies to the next connection.
    static let connectionTimeoutSeconds = "connection_timeout_seconds"
    static let connectionTimeoutChoices = [5, 10, 15, 20, 30, 45, 60]
    /// Options > Separate Window per BBS (Windows `AppSettings.MultiWindow`, PORT_TO_MAC_LINUX §12.57): each
    /// connection opens in a window (and an instance of the app) of its own, several at once. Default true; off,
    /// connecting takes over the main window as before. Read at connect time (`SessionLauncher.launchesSessions`).
    static let multiWindow = "multi_window"
    /// Settings > Graphical Windows on Rainwire Boards (Windows `AppSettings.RainwireGraphicalWindows`, 2026-10-05):
    /// a Rainwire board's windows, taskbar and start menu drawn as graphical windows (RainwireWm/WmChrome.swift), or
    /// off, in the board's own text cells. Default true. The desk layer applies it the moment it changes.
    static let rainwireGraphicalWindows = "rainwire_graphical_windows"
    /// Settings > Board Notifications (12.72): the board's OSC 777 notifications as macOS notifications while the
    /// window isn't in front, and notify=1 in the Rainwire:Caps answer. Default false; turning it on asks macOS for
    /// permission. Read at connect time (`OscExtras.notificationsAllowed`) and for each notification.
    static let boardNotifications = "board_notifications_enabled"
    /// Options > Let Boards Open Extra Windows (Windows `AppSettings.LinkedWindows`, 12.73): mw=1 in the Rainwire:Caps
    /// answer, so a board may open a linked window onto the call (Rainwire's MRC, Dead Modem TV). Default true. Read
    /// at connect time and again when the board asks (`LinkedWindows`).
    static let linkedWindows = "linked_windows"
    /// Linked windows kept above other windows (View > Always on Top), by their id "<parentId>-<kind>" (Windows
    /// `AppSettings.LinkedWindowsOnTop`): an array of strings.
    static let linkedWindowsOnTop = "linked_windows_on_top"

    /// The connection timeout setting, in seconds; a missing or invalid value is 10 (Windows `ValidConnectionTimeout`).
    static var connectionTimeout: Int {
        let stored = UserDefaults.standard.object(forKey: connectionTimeoutSeconds) as? Int ?? 10
        return connectionTimeoutChoices.contains(stored) ? stored : 10
    }

    /// Quick Connect slot ids (1–4). Slots 3–4 only show in the side-by-side layout but stay
    /// saved while hidden. Same key shape the original two slots always used.
    static func quickConnectKey(_ slot: Int) -> String { "quick_connect_\(slot)_id" }

    /// Registers the defaults and applies the first-run rule. Call once, before anything
    /// else touches UserDefaults (in particular before `BBSEntryStore.shared` seeds the phonebook,
    /// because a seeded phonebook is what marks an existing install).
    static func registerDefaults() {
        let defaults = UserDefaults.standard

        // First run = nothing this app ever persists is there yet: no phonebook, no saved window,
        // and no explicit layout choice. Upgraders have at least the phonebook.
        let isFirstRun = defaults.object(forKey: homeSideBySide) == nil
            && defaults.object(forKey: "bbs_entries") == nil
            && defaults.object(forKey: WindowSizeManager.widthKey) == nil
        if isFirstRun {
            defaults.set(true, forKey: homeSideBySide)
        }

        defaults.register(defaults: [
            homeSideBySide: false,
            showBootSequence: true,
            screensaverEnabled: true,
            phosphor: PhosphorMode.color.rawValue,
            totalCalls: 0,
            emulatedBaud: 0,
            showModemLights: true,
            keyClicksEnabled: false,
            keyClickVolume: 3,
            zmodem8k: false,
            connectionTimeoutSeconds: 10,
            multiWindow: true,
            rainwireGraphicalWindows: true,
            boardNotifications: false,
            linkedWindows: true,
            TraceModules.keyEnabled: true,
            TraceModules.keyCacheLimitMb: 500,
        ])

        // A modem speed saved before the list followed the real standards (57600 / 115200) moves to the nearest one
        if defaults.object(forKey: emulatedBaud) != nil {
            let stored = defaults.integer(forKey: emulatedBaud)
            let normalized = ModemSpeeds.normalize(stored)
            if normalized != stored {
                defaults.set(normalized, forKey: emulatedBaud)
            }
        }
    }
}
