import Foundation
import CoreGraphics

/// Screen mode presets matching Android implementation.
enum ScreenMode: Int, CaseIterable, Codable, Identifiable {
    case mode80x25 = 0
    case mode80x30 = 1
    case mode80x50 = 2
    case mode132x25 = 3
    case mode132x50 = 4
    case mode80x40 = 5
    case mode132x30 = 6
    case mode132x40 = 7
    case mode132x60 = 8
    // macOS PETSCII 2026-09-04 — indices MUST match ios_to_native_screen_mode[]
    // in syncterm_macos.c, and they are persisted in the phonebook, so APPEND only.
    case modeC64 = 9
    case modeC128_40 = 10
    case modeC128_80 = 11

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .mode80x25: return "80x25"
        case .mode80x30: return "80x30"
        case .mode80x40: return "80x40"
        case .mode80x50: return "80x50"
        case .mode132x25: return "132x25"
        case .mode132x30: return "132x30"
        case .mode132x40: return "132x40"
        case .mode132x50: return "132x50"
        case .mode132x60: return "132x60"
        case .modeC64: return "C64 40x25 (PETSCII)"
        case .modeC128_40: return "C128 40x25 (PETSCII)"
        case .modeC128_80: return "C128 80x25 (PETSCII)"
        }
    }

    var columns: Int {
        switch self {
        case .mode80x25, .mode80x30, .mode80x40, .mode80x50: return 80
        case .mode132x25, .mode132x30, .mode132x40, .mode132x50, .mode132x60: return 132
        case .modeC64, .modeC128_40: return 40
        case .modeC128_80: return 80
        }
    }

    var rows: Int {
        switch self {
        case .mode80x25, .mode132x25: return 25
        case .mode80x30, .mode132x30: return 30
        case .mode80x40, .mode132x40: return 40
        case .mode80x50, .mode132x50: return 50
        case .mode132x60: return 60
        case .modeC64, .modeC128_40, .modeC128_80: return 25
        }
    }

    // ---- macOS PETSCII 2026-09-04 (mirrors the shipping iOS build) ----------

    /// True for the Commodore (PETSCII) screen modes.
    var isCommodore: Bool {
        switch self {
        case .modeC64, .modeC128_40, .modeC128_80: return true
        default: return false
        }
    }

    /// Display aspect (width/height) to draw the mode at, never nil for anything the
    /// app offers.
    ///
    /// Every mode keeps the CHARACTER CELL shape of an 80x25 screen on a 4:3 monitor
    /// (no text mode had square pixels: 80x25 is a 720x400 grid that filled a 4:3
    /// monitor), and the picture grows with the grid: 80x25 is 4:3, 80x50 is twice as
    /// tall (2:3), 132x25 is 132/80 as wide, 132x50 about 1.1:1. The 40-column
    /// Commodore modes keep their own 6:5 (320x200). User's call 2026-10-01 (replaces
    /// the 2026-09-12 rows-only scaling, which squeezed 132-column modes).
    var displayAspect: CGFloat? {
        switch self {
        case .modeC64, .modeC128_40: return 6.0 / 5.0
        default:
            guard columns > 0, rows > 0 else { return 4.0 / 3.0 }
            return 4.0 / 3.0 * (CGFloat(columns) / 80.0) * (25.0 / CGFloat(rows))
        }
    }

    /// The conio font a Commodore mode starts in: the LOWER (text) set.
    ///
    /// ⚠️ Not the upper/graphics set. C64 terminal programs run in text mode and
    /// boards send lowercase ASCII before any PETSCII detection, which renders as
    /// graphics junk in the UPPER set. cterm's own 0x0E / 0x8E switch takes it from
    /// there, and a manual upper/lower option was deliberately REMOVED as redundant
    /// on Windows — do not add one back.
    var commodoreFontName: String? {
        switch self {
        case .modeC64: return "Commodore 64 (Lower)"
        case .modeC128_40, .modeC128_80: return "Commodore 128 (Lower)"
        default: return nil
        }
    }
}

/// Connection protocol types.
///
/// ⚠️ The raw values are the native CONN_TYPE_* ordinals from syncterm/conn.h —
/// they are handed straight to native_connect() — and they are also persisted in
/// the phonebook, so they can never be renumbered.
enum ConnectionProtocol: Int, CaseIterable, Codable, Identifiable {
    case telnet = 3
    /// A plain 8-bit socket: no telnet negotiation, no IAC handling.
    ///
    /// Not every board listening on port 23 actually speaks telnet. Against one that
    /// does not, our telnet layer eats any 0xFF in the stream as an IAC command.
    /// ZMODEM shrugs that off because it escapes IAC itself before the bytes reach the
    /// wire, but X/YMODEM blocks ARE raw file bytes — so an XMODEM download CRCs,
    /// retries and dies while ZMODEM on the same board is perfectly happy. Raw is the
    /// escape hatch for exactly that, and it is why IcyTerm exposes a connection-type
    /// picker too.
    case raw = 4
    case ssh = 5
    case telnetS = 13
    case webSocket = 14
    case secureWebSocket = 15

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .telnet: return "Telnet"
        case .raw: return "Raw (no telnet)"
        case .ssh: return "SSH"
        case .telnetS: return "TelnetS (TLS)"
        case .webSocket: return "WebSocket (ws://)"
        case .secureWebSocket: return "Secure WebSocket (wss://)"
        }
    }

    /// Default TCP port. Mirrors conn_ports[] in syncterm/conn.c.
    var defaultPort: Int {
        switch self {
        case .telnet: return 23
        // Same 23 as Telnet on purpose: Raw exists for boards that answer on the
        // telnet port without speaking telnet.
        case .raw: return 23
        case .ssh: return 22
        case .telnetS: return 992
        case .webSocket: return 80
        case .secureWebSocket: return 443
        }
    }
}

/// Font options for terminal display.
/// Raw values must match font indices in allfonts.c
enum TerminalFont: Int, CaseIterable, Identifiable {
    case cp437 = 0              // Codepage 437 English - Standard DOS font (index 0)
    case p0tNoodle = 37         // P0T NOoDLE (Amiga)
    case moSoul = 38            // mO'sOul (Amiga)
    case microKnightPlus = 39   // MicroKnight Plus (Amiga)
    case topazPlus = 40         // Topaz Plus (Amiga)
    case microKnight = 41       // MicroKnight (Amiga)
    case topaz = 42             // Topaz (Amiga)

    var id: Int { rawValue }

    /// Display name shown in UI
    var displayName: String {
        switch self {
        case .cp437: return "Codepage 437 English"
        case .p0tNoodle: return "P0T NOoDLE"
        case .moSoul: return "mO'sOul"
        case .microKnightPlus: return "MicroKnight Plus"
        case .topazPlus: return "Topaz Plus"
        case .microKnight: return "MicroKnight"
        case .topaz: return "Topaz"
        }
    }

    /// Internal font name that matches SyncTERM allfonts.c descriptions
    var fontName: String {
        switch self {
        case .cp437: return "Codepage 437 English"
        case .p0tNoodle: return "P0T NOoDLE (Amiga)"
        case .moSoul: return "mO'sOul (Amiga)"
        case .microKnightPlus: return "MicroKnight Plus (Amiga)"
        case .topazPlus: return "Topaz Plus (Amiga)"
        case .microKnight: return "MicroKnight (Amiga)"
        case .topaz: return "Topaz (Amiga)"
        }
    }
}

// Custom Codable to handle migration from old rawValue (1) to new (40) for topazPlus
extension TerminalFont: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)

        // Handle migration: old value 1 mapped to topazPlus (now 40)
        if rawValue == 1 {
            self = .topazPlus
        } else if let font = TerminalFont(rawValue: rawValue) {
            self = font
        } else {
            // Default to cp437 for unknown values
            self = .cp437
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Represents a BBS connection entry with all configuration.
struct BBSEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var connectionProtocol: ConnectionProtocol
    var username: String
    var screenMode: ScreenMode
    var font: TerminalFont
    /// ⚠️ INERT since 2026-09-12. Nothing reads this any more — the terminal has no zoom, on
    /// any client. It is kept because it is already in every saved phonebook and in the
    /// import/export XML, so dropping it would change the on-disk format for no gain. Give it
    /// a meaning again only if terminal zoom is actually built.
    var zoomLevel: Int  // 25-200%
    var showStatusBar: Bool
    /// ⚠️ INERT, like [zoomLevel]. The edit sheet used to load and save this without ever
    /// showing a control for it, and nothing read it. Kept only so saved phonebooks and the
    /// import/export XML keep their shape.
    var showButtonBar: Bool
    /// ⚠️ INERT. Never read by anything — no client connects on launch. Kept for the same
    /// on-disk-format reason as the two above.
    var autoConnect: Bool
    var snapshotData: Data?  // Thumbnail/snapshot image data
    var createdAt: Date
    var lastConnected: Date?

    // Note: Password is NOT stored here - use KeychainManager instead

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 23,
        connectionProtocol: ConnectionProtocol = .telnet,
        username: String = "",
        screenMode: ScreenMode = .mode80x25,
        font: TerminalFont = .cp437,
        zoomLevel: Int = 100,
        showStatusBar: Bool = true,
        showButtonBar: Bool = true,
        autoConnect: Bool = false,
        snapshotData: Data? = nil,
        createdAt: Date = Date(),
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.connectionProtocol = connectionProtocol
        self.username = username
        self.screenMode = screenMode
        self.font = font
        self.zoomLevel = zoomLevel.clamped(to: 25...200)
        self.showStatusBar = showStatusBar
        self.showButtonBar = showButtonBar
        self.autoConnect = autoConnect
        self.snapshotData = snapshotData
        self.createdAt = createdAt
        self.lastConnected = lastConnected
    }

    // MARK: - Codable (with defaults for new fields)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        connectionProtocol = try container.decode(ConnectionProtocol.self, forKey: .connectionProtocol)
        username = try container.decode(String.self, forKey: .username)
        screenMode = try container.decode(ScreenMode.self, forKey: .screenMode)
        font = try container.decode(TerminalFont.self, forKey: .font)
        zoomLevel = (try container.decodeIfPresent(Int.self, forKey: .zoomLevel) ?? 100).clamped(to: 25...200)
        showStatusBar = try container.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? true
        showButtonBar = try container.decodeIfPresent(Bool.self, forKey: .showButtonBar) ?? true
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        snapshotData = try container.decodeIfPresent(Data.self, forKey: .snapshotData)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
    }

    // MARK: - Password Management (via Keychain)

    /// Get the password from secure Keychain storage.
    var password: String? {
        KeychainManager.shared.getPassword(for: id)
    }

    /// SSH with no saved password (Save Credentials off): connect with no questions and let the board log the
    /// caller in itself, the way Rainwire does. The SSH layer gets user "bbs" and a password Rainwire ignores,
    /// never the entry's username (that would count as a failed login for it). A board that wants an SSH password
    /// says so and the call ends. With a saved password, the username/password are used at the SSH layer as
    /// before. The client key (ssh_keys.p15) is never offered either way (ssh.c ssh_offer_key).
    var usesBlankSshLogin: Bool {
        connectionProtocol == .ssh && (password ?? "").isEmpty
    }

    /// Set the password in secure Keychain storage.
    func setPassword(_ password: String?) {
        if let password = password, !password.isEmpty {
            KeychainManager.shared.savePassword(password, for: id)
        } else {
            KeychainManager.shared.deletePassword(for: id)
        }
    }

    /// Check if a password is stored for this entry.
    var hasPassword: Bool {
        KeychainManager.shared.hasPassword(for: id)
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: BBSEntry, rhs: BBSEntry) -> Bool {
        // Include snapshotData in equality check so SwiftUI detects thumbnail changes
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.host == rhs.host &&
        lhs.port == rhs.port &&
        lhs.snapshotData == rhs.snapshotData
    }

    // MARK: - Default Port

    /// Get the default port for the current protocol.
    var defaultPort: Int { connectionProtocol.defaultPort }

    // MARK: - Display Helpers

    /// Display string for the connection address.
    var addressDisplay: String {
        if port == defaultPort {
            return host
        }
        return "\(host):\(port)"
    }

    /// Connection description for display.
    var connectionDescription: String {
        "\(connectionProtocol.displayName) - \(screenMode.displayName)"
    }
}

// MARK: - Comparable Extension

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - BBSEntry Storage

/// Manages persistent storage of BBS entries.
class BBSEntryStore: ObservableObject {
    static let shared = BBSEntryStore()

    // Fixed UUID for Dead Modem Society so Quick Connect 2 can default to it
    static let deadModemSocietyUUID = UUID(uuidString: "DEADBEEF-DEAD-DEAD-DEAD-DEAD00DE0500")!

    @Published var entries: [BBSEntry] = []
    @Published var isSortedAlphabetically: Bool = false

    /// Snapshot of the manual ordering before alphabetical sort was applied.
    private var originalOrder: [BBSEntry] = []

    private let storageKey = "bbs_entries"

    // Several instances of the app share the phonebook (the main window, and one instance per BBS window, PORT_TO_MAC_
    // LINUX §12.57), so a save doesn't write out this instance's list as it stands: it re-reads the stored phonebook
    // under `AppDataLock` and applies only what changed here since the last load or save -- entries edited, added or
    // removed, and the order if it was changed here. A BBS window's own saves (its last call, a snapshot) therefore
    // can't undo an edit made in the main window meanwhile. The last-connected time always keeps the later of the two.

    /// Each entry as this instance last loaded or saved it, and their order: what a save compares against.
    private var baseline: [UUID: Data] = [:]
    private var baselineOrder: [UUID] = []
    /// The stored phonebook as last read or written here (`reloadIfChanged`).
    private var baselineBlob: Data?

    /// Sorted keys, so the same entry always encodes to the same bytes.
    private static let compareEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private init() {
        loadEntries()
    }

    private func setBaseline(blob: Data?) {
        baseline = [:]
        for entry in entries where baseline[entry.id] == nil {
            baseline[entry.id] = try? Self.compareEncoder.encode(entry)
        }
        baselineOrder = entries.map { $0.id }
        baselineBlob = blob
    }

    func loadEntries() {
        AppDataLock.withLock {
            AppDataLock.refreshDefaults()
            let blob = UserDefaults.standard.data(forKey: storageKey)
            if let data = blob {
                do {
                    entries = try JSONDecoder().decode([BBSEntry].self, from: data)
                } catch {
                    print("Failed to decode BBS entries: \(error)")
                    entries = []
                }
            }
            setBaseline(blob: blob)
        }

        if entries.isEmpty {
            addDefaultEntries()
        } else {
            migrateDefaults()
        }

        // Fill in missing snapshots for default entries from bundle
        repairDefaultSnapshots()
    }

    /// Fill in missing snapshot images for default BBS entries from app bundle.
    private func repairDefaultSnapshots() {
        let snapshotMap: [String: String] = [
            "absinthebbs.net": "snapshot_absinthe",
            "telnet.deadmodemsociety.com": "snapshot_deadmodem",
            "20forbeers.com": "snapshot_20forbeers",
            "bbs.bottomlessabyss.net": "snapshot_bottomlessabyss",
            "sbbs.dmine.net": "snapshot_diamondmine",
            "bbs.erb.pw": "snapshot_quantumwormhole",
            "dura-bbs.net": "snapshot_duraeuropos",
            "wizardsrainbow.com": "snapshot_wizardsrainbow",
            "xibalba.l33t.codes": "snapshot_xibalba",
            "d1st.org": "snapshot_distortion"
        ]
        var changed = false
        for i in entries.indices {
            guard entries[i].snapshotData == nil,
                  let resource = snapshotMap[entries[i].host],
                  let url = Bundle.main.url(forResource: resource, withExtension: "png"),
                  let data = try? Data(contentsOf: url) else { continue }
            entries[i].snapshotData = data
            changed = true
        }
        if changed {
            saveEntries()
        }
    }

    /// All default BBSes with their configuration and bundle snapshot resource names.
    private static let allDefaults: [(name: String, host: String, port: Int, screenMode: ScreenMode, font: TerminalFont, id: UUID?, snapshotResource: String?)] = [
        ("aBSiNTHE BBS", "absinthebbs.net", 1940, .mode80x50, .topazPlus, nil, "snapshot_absinthe"),
        ("Dead Modem Society", "telnet.deadmodemsociety.com", 1337, .mode80x25, .cp437, deadModemSocietyUUID, "snapshot_deadmodem"),
        ("20 For Beers", "20forbeers.com", 1337, .mode80x25, .cp437, nil, "snapshot_20forbeers"),
        ("The Bottomless Abyss", "bbs.bottomlessabyss.net", 2023, .mode80x25, .cp437, nil, "snapshot_bottomlessabyss"),
        ("Diamond Mine Online", "sbbs.dmine.net", 24, .mode80x25, .cp437, nil, "snapshot_diamondmine"),
        ("The Quantum Wormhole", "bbs.erb.pw", 23, .mode80x25, .cp437, nil, "snapshot_quantumwormhole"),
        ("Dura-Europos", "dura-bbs.net", 6359, .mode80x25, .cp437, nil, "snapshot_duraeuropos"),
        ("Wizard's Rainbow", "wizardsrainbow.com", 23, .mode80x25, .cp437, nil, "snapshot_wizardsrainbow"),
        ("Xibalba", "xibalba.l33t.codes", 44510, .mode80x25, .cp437, nil, "snapshot_xibalba"),
        ("Distortion", "d1st.org", 23, .mode80x25, .cp437, nil, "snapshot_distortion"),
    ]

    private static let currentDefaultsVersion = 7

    /// Add default BBS connections on fresh install.
    private func addDefaultEntries() {
        entries = BBSEntryStore.allDefaults.map { def in
            let snapshot: Data? = def.snapshotResource.flatMap { resource in
                Bundle.main.url(forResource: resource, withExtension: "png")
                    .flatMap { try? Data(contentsOf: $0) }
            }
            return BBSEntry(
                id: def.id ?? UUID(),
                name: def.name,
                host: def.host,
                port: def.port,
                connectionProtocol: .telnet,
                screenMode: def.screenMode,
                font: def.font,
                showStatusBar: true,
                snapshotData: snapshot
            )
        }
        UserDefaults.standard.set(BBSEntryStore.currentDefaultsVersion, forKey: "defaults_version")
        saveEntries()
    }

    /// Migrate new default BBSes for existing users, skipping duplicates by host+port.
    private func migrateDefaults() {
        let version = UserDefaults.standard.integer(forKey: "defaults_version")
        if version >= BBSEntryStore.currentDefaultsVersion { return }

        var changed = false

        // Version 4: Update aBSiNTHE BBS to 80x50 screen mode
        if version < 4 {
            for i in entries.indices {
                if entries[i].host == "absinthebbs.net" && entries[i].port == 1940 {
                    if entries[i].screenMode != .mode80x50 {
                        entries[i].screenMode = .mode80x50
                        changed = true
                    }
                }
            }
        }

        // Version 5: Refresh default BBS snapshots with updated artwork
        if version >= 1 && version < 5 {
            refreshDefaultSnapshots()
            changed = true
        }

        // Version 6: Refresh 20 For Beers snapshot with updated artwork
        if version >= 5 && version < 6 {
            refreshDefaultSnapshots()
            changed = true
        }

        // Version 7: Refresh 20 For Beers snapshot with new artwork
        if version >= 6 && version < 7 {
            refreshDefaultSnapshots()
            changed = true
        }

        // Add any new default BBSes (skipping duplicates)
        let existing = Set(entries.map { "\($0.host):\($0.port)" })

        for def in BBSEntryStore.allDefaults {
            let key = "\(def.host):\(def.port)"
            if existing.contains(key) { continue }

            let snapshot: Data? = def.snapshotResource.flatMap { resource in
                Bundle.main.url(forResource: resource, withExtension: "png")
                    .flatMap { try? Data(contentsOf: $0) }
            }
            let entry = BBSEntry(
                id: def.id ?? UUID(),
                name: def.name,
                host: def.host,
                port: def.port,
                connectionProtocol: .telnet,
                screenMode: def.screenMode,
                font: def.font,
                showStatusBar: true,
                snapshotData: snapshot
            )
            entries.append(entry)
            changed = true
        }

        UserDefaults.standard.set(BBSEntryStore.currentDefaultsVersion, forKey: "defaults_version")
        if changed {
            saveEntries()
        }
    }

    /// Force-refresh snapshot images for all default BBSes from bundled assets.
    private func refreshDefaultSnapshots() {
        let snapshotMap: [String: String] = [
            "absinthebbs.net": "snapshot_absinthe",
            "telnet.deadmodemsociety.com": "snapshot_deadmodem",
            "20forbeers.com": "snapshot_20forbeers",
            "bbs.bottomlessabyss.net": "snapshot_bottomlessabyss",
            "sbbs.dmine.net": "snapshot_diamondmine",
            "bbs.erb.pw": "snapshot_quantumwormhole",
            "dura-bbs.net": "snapshot_duraeuropos",
            "wizardsrainbow.com": "snapshot_wizardsrainbow",
            "xibalba.l33t.codes": "snapshot_xibalba",
            "d1st.org": "snapshot_distortion"
        ]
        for i in entries.indices {
            guard let resource = snapshotMap[entries[i].host],
                  let url = Bundle.main.url(forResource: resource, withExtension: "png"),
                  let data = try? Data(contentsOf: url) else { continue }
            entries[i].snapshotData = data
        }
    }

    func saveEntries() {
        AppDataLock.withLock {
            AppDataLock.refreshDefaults()
            var disk: [BBSEntry] = UserDefaults.standard.data(forKey: storageKey)
                .flatMap { try? JSONDecoder().decode([BBSEntry].self, from: $0) } ?? []
            let mine = Set(entries.map { $0.id })

            // Removed here
            disk.removeAll { baseline[$0.id] != nil && !mine.contains($0.id) }

            // Edited or added here. The last call is the later of the two, since a BBS window records its own.
            for var entry in entries {
                let encoded = try? Self.compareEncoder.encode(entry)
                let changed = baseline[entry.id] == nil || baseline[entry.id] != encoded
                if let index = disk.firstIndex(where: { $0.id == entry.id }) {
                    if let theirs = disk[index].lastConnected, theirs > (entry.lastConnected ?? .distantPast) {
                        entry.lastConnected = theirs
                    }
                    if changed {
                        disk[index] = entry
                    }
                } else if changed {
                    disk.append(entry)
                }
            }

            // The order, if it was changed here: this instance's order, with anything added elsewhere after it
            if entries.map({ $0.id }) != baselineOrder {
                var rank: [UUID: Int] = [:]
                for (index, entry) in entries.enumerated() where rank[entry.id] == nil {
                    rank[entry.id] = index
                }
                disk = disk.enumerated().sorted { a, b in
                    let rankA = rank[a.element.id] ?? Int.max
                    let rankB = rank[b.element.id] ?? Int.max
                    return rankA != rankB ? rankA < rankB : a.offset < b.offset
                }.map { $0.element }
            }

            do {
                let data = try JSONEncoder().encode(disk)
                UserDefaults.standard.set(data, forKey: storageKey)
                AppDataLock.refreshDefaults()
                entries = disk
                setBaseline(blob: data)
            } catch {
                print("Failed to encode BBS entries: \(error)")
            }
        }
    }

    /// Re-reads the phonebook if another instance saved it since this one last loaded or saved (the main window,
    /// coming back to the front). True when it was re-read.
    @discardableResult
    func reloadIfChanged() -> Bool {
        AppDataLock.withLock { () -> Bool in
            AppDataLock.refreshDefaults()
            guard let data = UserDefaults.standard.data(forKey: storageKey), data != baselineBlob,
                  let decoded = try? JSONDecoder().decode([BBSEntry].self, from: data) else { return false }
            if isSortedAlphabetically {
                originalOrder = decoded
                entries = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } else {
                entries = decoded
            }
            setBaseline(blob: data)
            return true
        }
    }

    func addEntry(_ entry: BBSEntry) {
        entries.append(entry)
        saveEntries()
    }

    func updateEntry(_ entry: BBSEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            saveEntries()
        }
    }

    func deleteEntry(_ entry: BBSEntry) {
        // Delete password from Keychain
        KeychainManager.shared.deletePassword(for: entry.id)
        // Remove from entries
        entries.removeAll { $0.id == entry.id }
        saveEntries()
    }

    func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            KeychainManager.shared.deletePassword(for: entries[index].id)
        }
        entries.remove(atOffsets: offsets)
        saveEntries()
    }

    func sortEntriesAlphabetically() {
        if isSortedAlphabetically {
            // Restore original manual order
            entries = originalOrder
            isSortedAlphabetically = false
        } else {
            // Save current order, then sort
            originalOrder = entries
            entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            isSortedAlphabetically = true
        }
    }

    func moveEntries(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        saveEntries()
    }

    func updateLastConnected(for entry: BBSEntry) {
        if var updatedEntry = entries.first(where: { $0.id == entry.id }) {
            updatedEntry.lastConnected = Date()
            updateEntry(updatedEntry)
        }
    }

    /// Matched on host+port, mirroring TERMinator-Android's
    /// `TerminalActivity.updateConnectionThumbnail`: the picture belongs to the BOARD, so the
    /// first entry pointing at that host+port takes it. Falls back to the id when nothing matches
    /// (an entry edited mid-session).
    func updateSnapshot(_ data: Data?, for entry: BBSEntry) {
        let match = entries.first(where: { $0.host == entry.host && $0.port == entry.port })
            ?? entries.first(where: { $0.id == entry.id })
        if var updatedEntry = match {
            updatedEntry.snapshotData = data
            updateEntry(updatedEntry)
        }
    }

    /// Import entries from decoded array, merging or replacing existing.
    func importEntries(_ newEntries: [BBSEntry], replace: Bool = false) {
        if replace {
            // Delete the passwords of entries that are going away. An entry the file brings back
            // (same id) keeps its Keychain password, as Windows keeps its credential on Replace.
            let incoming = Set(newEntries.map { $0.id })
            for entry in entries where !incoming.contains(entry.id) {
                KeychainManager.shared.deletePassword(for: entry.id)
            }
            entries = newEntries
        } else {
            // Merge: update existing or add new
            for newEntry in newEntries {
                if let index = entries.firstIndex(where: { $0.id == newEntry.id }) {
                    entries[index] = newEntry
                } else {
                    entries.append(newEntry)
                }
            }
        }
        saveEntries()
    }
}
