import SwiftUI

/// Desktop-optimized settings view.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    // Bell Settings
    @ObservedObject private var bellManager = BellManager.shared

    // Soundtrack Settings
    @AppStorage(SoundtrackManager.keySoundtrackEnabled) private var soundtrackEnabled = true
    @AppStorage(SoundtrackManager.keySoundtrackCacheLimit) private var soundtrackCacheLimit = 250
    @ObservedObject private var soundtrackManager = SoundtrackManager.shared

    // TRACE (TERMinator Render And Compute Engine)
    @AppStorage(TraceModules.keyEnabled) private var traceEnabled = true
    @AppStorage(TraceModules.keyCacheLimitMb) private var traceCacheLimitMb = 500
    @State private var traceCacheDisplay = "0 KB (0 modules)"
    /// What the TRACE cache holds, one row per file (Windows `SettingsViewModel.TraceCacheItems`).
    @State private var traceCacheRows: [TraceCacheRow] = []
    @State private var traceCacheExpanded = false   // the list of cached files, folded away each time Settings opens

    // Terminal Settings
    @AppStorage("default_font") private var defaultFontRaw: Int = TerminalFont.cp437.rawValue
    @AppStorage("default_screen_mode") private var defaultScreenModeRaw: Int = ScreenMode.mode80x25.rawValue
    @AppStorage("font_smoothing") private var fontSmoothing = false
    @AppStorage(AppPreferences.rainwireGraphicalWindows) private var rainwireGraphicalWindows = true
    @AppStorage(AppPreferences.connectionTimeoutSeconds) private var connectionTimeoutSeconds = 10

    // File Transfer Settings
    @AppStorage("auto_detect_zmodem") private var autoDetectZmodem = true
    @AppStorage("download_directory") private var downloadDirectory: String = ""

    // Logging Settings
    @AppStorage("logging_enabled") private var loggingEnabled = false
    @AppStorage("log_directory") private var logDirectory: String = ""

    // Display Settings (also in the View and Options menus). Written the moment they change, like every setting on
    // this screen, so a phosphor pick shows straight away.
    @AppStorage(AppPreferences.showBootSequence) private var showBootSequence = true
    @AppStorage(AppPreferences.screensaverEnabled) private var screensaverEnabled = true
    @AppStorage(AppPreferences.homeSideBySide) private var homeSideBySide = false
    @AppStorage(AppPreferences.phosphor) private var phosphor = PhosphorMode.color.rawValue

    // Modem Settings
    @AppStorage(AppPreferences.emulatedBaud) private var emulatedBaud = 0
    @AppStorage(AppPreferences.showModemLights) private var showModemLights = true
    @AppStorage(AppPreferences.keyClicksEnabled) private var keyClicksEnabled = false
    @AppStorage(AppPreferences.keyClickVolume) private var keyClickVolume = 3

    // Board notifications (12.72)
    @AppStorage(AppPreferences.boardNotifications) private var boardNotifications = false

    // Alert state
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    // Help sheet state
    @State private var showingHelp = false

    /// The settings column's width (Windows: 600).
    private static let columnWidth: CGFloat = 600

    /// What this screen's settings were when it opened, for CANCEL. Windows edits a copy that only
    /// SAVE writes; here every control writes the moment it changes (so a phosphor pick shows at once),
    /// so CANCEL puts the opening values back instead. Static, not @State: Screensaver TEST re-creates
    /// this view while Settings is still the screen, and the snapshot has to outlive that.
    private static var opening: OpeningValues?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header, top left (Windows)
            VStack(alignment: .leading, spacing: 4) {
                Text("SETTINGS")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(.amberAccent)
                Text("Application Preferences")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.textSecondary)
            }
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 0) {
                    bellSettingsSection
                    terminalSettingsSection
                    displaySettingsSection
                    modemSettingsSection
                    soundtrackSettingsSection
                    traceSettingsSection
                    fileTransferSettingsSection
                    loggingSettingsSection
                    importExportSection
                    helpSection
                }
                // One fixed-width column centered in the window, as Windows' `StackPanel MaxWidth="600"`,
                // rather than sections stretched edge to edge.
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }

            // SAVE / CANCEL, bottom right (Windows)
            HStack(spacing: 10) {
                Spacer()
                RetroButton("SAVE", style: .amber) {
                    Self.opening = nil
                    appState.closeSettings()
                }
                RetroButton("CANCEL", style: .danger) {
                    Self.opening?.restore(bell: bellManager)
                    Self.opening = nil
                    appState.closeSettings()
                }
            }
            .padding(.top, 20)
        }
        .padding(24)
        .background(Color.background)
        .onAppear {
            if Self.opening == nil {
                Self.opening = OpeningValues(bell: bellManager)
            }
        }
        .onDisappear {
            // Left some other way (a menu, the console): the edits stand, and the next visit starts afresh
            if appState.currentView != .settings && !appState.settingsOverTerminal {
                Self.opening = nil
            }
        }
        .alert(alertTitle, isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
    }

    /// The preferences this screen edits, as they stood when it opened.
    private struct OpeningValues {
        /// Every `@AppStorage` key above. A key with nothing stored is absent, and CANCEL removes it again.
        static let keys = [
            "default_font", "default_screen_mode", "font_smoothing", AppPreferences.connectionTimeoutSeconds,
            AppPreferences.rainwireGraphicalWindows, AppPreferences.boardNotifications,
            "auto_detect_zmodem", "download_directory",
            "logging_enabled", "log_directory",
            AppPreferences.showBootSequence, AppPreferences.screensaverEnabled,
            AppPreferences.homeSideBySide, AppPreferences.phosphor,
            AppPreferences.emulatedBaud, AppPreferences.showModemLights,
            AppPreferences.keyClicksEnabled, AppPreferences.keyClickVolume,
            SoundtrackManager.keySoundtrackEnabled, SoundtrackManager.keySoundtrackCacheLimit,
            TraceModules.keyEnabled, TraceModules.keyCacheLimitMb,
        ]

        let defaults: [String: Any]
        // BellManager keeps its own published copies, so it is put back through them.
        let bellEnabled: Bool
        let bellSound: BellSound
        let bellVolume: Int

        init(bell: BellManager) {
            var values: [String: Any] = [:]
            for key in Self.keys {
                if let value = UserDefaults.standard.object(forKey: key) {
                    values[key] = value
                }
            }
            defaults = values
            bellEnabled = bell.soundEnabled
            bellSound = bell.bellSound
            bellVolume = bell.volumeLevel
        }

        func restore(bell: BellManager) {
            for key in Self.keys {
                if let value = defaults[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            bell.soundEnabled = bellEnabled
            bell.bellSound = bellSound
            bell.volumeLevel = bellVolume
        }
    }

    // MARK: - Section Header Helper

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            // Windows: AccentGreenBrush, 15, SemiBold
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundColor(.accentGreen)
            .textCase(.uppercase)
            .padding(.bottom, 6)
            .padding(.top, 16)
    }

    private func sectionBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.panelBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Bell Settings

    private var bellSettingsSection: some View {
        sectionBox("Bell") {
            Toggle("Sound Enabled", isOn: $bellManager.soundEnabled)
                .toggleStyle(.switch)

            if bellManager.soundEnabled {
                Picker("Bell Sound", selection: $bellManager.bellSound) {
                    ForEach(BellSound.allCases) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }

                Text(bellManager.bellSound.soundDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.textSecondary)

                HStack {
                    Text("Volume")
                    Slider(
                        value: Binding(
                            get: { Double(bellManager.volumeLevel) },
                            set: { bellManager.volumeLevel = Int($0.rounded()) }
                        ),
                        in: 0...10,
                        step: 1
                    )
                    Text("\(bellManager.volumeLevel * 10)%")
                        .frame(width: 40)
                        .foregroundColor(.textSecondary)
                }

                Button("Test Sound") {
                    bellManager.testSound(bellManager.bellSound)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Terminal Settings

    private var terminalSettingsSection: some View {
        sectionBox("Terminal") {
            Picker("Default Font", selection: Binding(
                get: { TerminalFont(rawValue: defaultFontRaw) ?? .cp437 },
                set: { defaultFontRaw = $0.rawValue }
            )) {
                ForEach(TerminalFont.allCases) { font in
                    Text(font.displayName).tag(font)
                }
            }

            Picker("Default Screen Mode", selection: Binding(
                get: { ScreenMode(rawValue: defaultScreenModeRaw) ?? .mode80x25 },
                set: { defaultScreenModeRaw = $0.rawValue }
            )) {
                ForEach(ScreenMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            // Windows: after Screen Mode, "Connection Timeout:" (PORT_TO_MAC_LINUX §12.27). An invalid stored value
            // shows as 10, like AppSettings.ValidConnectionTimeout.
            Picker("Connection Timeout:", selection: Binding(
                get: { AppPreferences.connectionTimeoutChoices.contains(connectionTimeoutSeconds)
                       ? connectionTimeoutSeconds : 10 },
                set: { connectionTimeoutSeconds = $0 }
            )) {
                ForEach(AppPreferences.connectionTimeoutChoices, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            .help("How long to wait for a BBS to answer before giving up.")

            Toggle("Font Smoothing (Anti-Aliasing)", isOn: $fontSmoothing)
                .toggleStyle(.switch)

            Toggle("Graphical Windows on Rainwire Boards", isOn: $rainwireGraphicalWindows)
                .toggleStyle(.switch)
                .help("On: a Rainwire board's windows, taskbar and start menu are drawn as real graphical windows. Off: in the board's own text look.")

            // The board's OSC 777 notifications (12.72). Off by default; turning it on asks macOS for permission.
            Toggle("Board Notifications", isOn: $boardNotifications)
                .toggleStyle(.switch)
                .onChange(of: boardNotifications) { enabled in
                    guard enabled else { return }
                    BoardNotifier.requestPermission { allowed in
                        if !allowed {
                            // Turned down now or before: the setting stays on, macOS just won't show them
                            alertTitle = "Notifications Are Off"
                            alertMessage = "macOS isn't letting TERMinator show notifications. Turn them on in System Settings > Notifications > TERMinator."
                            showingAlert = true
                        }
                    }
                }
            Text("Show a system notification when the board pages you or sends you a message while TERMinator is in the background.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Display Settings

    private var displaySettingsSection: some View {
        sectionBox("Display") {
            Toggle("Boot Sequence on Startup", isOn: $showBootSequence)
                .toggleStyle(.switch)

            HStack(spacing: 16) {
                Toggle("Screensaver", isOn: $screensaverEnabled)
                    .toggleStyle(.switch)
                Button("TEST") {
                    NotificationCenter.default.post(name: .startScreensaver, object: nil)
                }
                .buttonStyle(.bordered)
                .help("Play the screensaver now")
            }

            Toggle("Side-by-Side Home Screen", isOn: $homeSideBySide)
                .toggleStyle(.switch)

            Picker("Phosphor", selection: $phosphor) {
                ForEach(PhosphorMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode.rawValue)
                }
            }

            HStack(spacing: 16) {
                Text("CRT / Scanline Effect")
                Button("CRT Settings...") {
                    CrtSettingsWindow.show()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Modem Settings

    private var modemSettingsSection: some View {
        sectionBox("Modem") {
            Picker("Emulated Speed", selection: $emulatedBaud) {
                ForEach(ModemSpeeds.rates, id: \.self) { bps in
                    Text(ModemSpeeds.label(bps)).tag(bps)
                }
            }

            Toggle("Show Modem Lights in the Status Bar", isOn: $showModemLights)
                .toggleStyle(.switch)

            Toggle("IBM Model M Key Clicks", isOn: $keyClicksEnabled)
                .toggleStyle(.switch)

            HStack {
                Text("Key Click Volume")
                Slider(
                    value: Binding(
                        get: { Double(keyClickVolume) },
                        set: { keyClickVolume = Int($0.rounded()) }
                    ),
                    in: 0...10,
                    step: 1
                )
                Text("\(keyClickVolume * 10)%")
                    .frame(width: 40)
                    .foregroundColor(.textSecondary)
            }

            Button("Test Click") {
                KeyClickService.shared.playPreview(volume: keyClickVolume)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Soundtrack Settings

    private var soundtrackSettingsSection: some View {
        sectionBox("TAP+ Terminal Audio Protocol") {
            Toggle("Enabled", isOn: $soundtrackEnabled)
                .toggleStyle(.switch)

            if soundtrackEnabled {
                Picker("Cache Limit", selection: $soundtrackCacheLimit) {
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                }

                HStack {
                    Text("Cache Used")
                    Spacer()
                    Text(formatBytes(soundtrackManager.cacheSize))
                        .foregroundColor(.textSecondary)
                }

                Button("Clear Cache") {
                    soundtrackManager.clearCache()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
    }

    // MARK: - TRACE Settings

    /// Windows `SettingsView.xaml` "TRACE (TERMinator Render And Compute Engine)", right under TAP+. Player-facing
    /// wording is always "TRACE graphics". Switching it off clears the Query reply and stops running modules with
    /// Closed;...;error=disabled (TraceSessionManager.applySettings), so doors fall back to their own graphics.
    private var traceSettingsSection: some View {
        sectionBox("TRACE (TERMinator Render And Compute Engine)") {
            Toggle("TRACE Graphics", isOn: $traceEnabled)
                .toggleStyle(.switch)
                .help("Lets doors draw with your PC's own processing power. Doors send their graphics modules, which run in a sandbox.")

            Picker("Cache Limit:", selection: $traceCacheLimitMb) {
                Text("100 MB").tag(100)
                Text("250 MB").tag(250)
                Text("500 MB").tag(500)
            }

            HStack {
                Text("Cache Size:")
                Spacer()
                Text(traceCacheDisplay)
                    .foregroundColor(.textSecondary)
                RetroButton("CLEAR CACHE", style: .danger) {
                    TraceModules.clearCache(keep: TraceSessionManager.shared.filesInUse)  // what a running module uses stays
                    updateTraceCacheDisplay()
                }
            }

            HStack {
                Text("Cached Files:")
                Spacer()
                RetroButton(traceCacheExpanded ? "HIDE" : "SHOW (\(traceCacheRows.count))") {
                    traceCacheExpanded.toggle()
                }
            }

            // What's cached, one row per file (TraceModules.listCache), each with its own DELETE. DELETE is
            // disabled, and the row says "in use", while a running module has the file.
            if traceCacheExpanded {
            ForEach(traceCacheRows) { row in
                HStack {
                    Text(row.text)
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    RetroButton("DELETE", style: .danger) {
                        TraceModules.deleteCached(row.url, inUse: TraceSessionManager.shared.filesInUse)
                        updateTraceCacheDisplay()
                    }
                    .disabled(!row.canDelete)
                    .opacity(row.canDelete ? 1.0 : 0.5)
                    .help("Removes this file from the cache. The door sends it again next time it's needed.")
                }
            }
            }
        }
        .onAppear {
            traceCacheExpanded = false
            updateTraceCacheDisplay()
        }
    }

    /// One file in the TRACE cache, as Settings lists it (Windows `TraceCacheRow`).
    private struct TraceCacheRow: Identifiable {
        let url: URL
        let text: String
        let canDelete: Bool

        var id: String { url.path }
    }

    /// "<size> (<n> modules)" and the rows, as Windows' `SettingsViewModel.UpdateTraceCacheDisplay`.
    private func updateTraceCacheDisplay() {
        let bytes = TraceModules.cacheSize()
        let count = TraceModules.cachedModuleCount()
        traceCacheDisplay = "\(formatCacheBytes(bytes)) (\(count) module\(count == 1 ? "" : "s"))"

        let inUse = TraceSessionManager.shared.filesInUse
        traceCacheRows = TraceModules.listCache().map { entry in
            let busy = TraceModules.isInUse(entry.url, inUse)
            return TraceCacheRow(url: entry.url, text: describeTraceCacheEntry(entry, inUse: busy), canDelete: !busy)
        }
    }

    private func formatCacheBytes(_ bytes: Int64) -> String {
        bytes < 1024 * 1024
            ? String(format: "%.0f KB", Double(bytes) / 1024.0)
            : String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }

    /// "tyrian · game · 396 KB · Absinthe BBS · used today": the door's module id (Unknown when it was cached before
    /// TERMinator recorded that), game (the module) or data (an asset), size, the board (left out when not known),
    /// and when it was last used, or "in use" while a running module has it. As Windows' `DescribeTraceCacheEntry`.
    private func describeTraceCacheEntry(_ entry: TraceModules.CacheEntry, inUse: Bool) -> String {
        // A file the player imported: "Wing Commander · your file · 4.1 MB · 2 boards allowed · used today"
        if entry.imported {
            return [entry.name ?? "Imported file", "your file", formatCacheBytes(entry.size),
                    entry.grantCount == 1 ? "1 board allowed" : "\(entry.grantCount) boards allowed",
                    inUse ? "in use" : formatLastUsed(entry.lastUsed)].joined(separator: " · ")
        }
        var parts = [entry.moduleId ?? "Unknown", entry.isAsset ? "data" : "game", formatCacheBytes(entry.size)]
        if let bbs = entry.bbs {
            parts.append(bbs)
        }
        parts.append(inUse ? "in use" : formatLastUsed(entry.lastUsed))
        return parts.joined(separator: " · ")
    }

    /// "used today", "used yesterday", "used 5 days ago" (under 30 days), else "used Sep 3, 2026".
    private func formatLastUsed(_ date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        if days <= 0 {
            return "used today"
        }
        if days == 1 {
            return "used yesterday"
        }
        if days < 30 {
            return "used \(days) days ago"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return "used \(formatter.string(from: date))"
    }

    // MARK: - File Transfer Settings

    private var fileTransferSettingsSection: some View {
        sectionBox("File Transfer") {
            Toggle("Auto-Detect ZMODEM", isOn: $autoDetectZmodem)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 4) {
                Text("Download Directory")
                HStack {
                    TextField("", text: $downloadDirectory, prompt: Text(defaultDownloadDirectory))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                    Button("…") {
                        chooseDirectory(prompt: "Select Download Directory",
                                        current: downloadDirectory.isEmpty ? defaultDownloadDirectory : downloadDirectory) { path in
                            downloadDirectory = path
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Logging Settings

    private var loggingSettingsSection: some View {
        sectionBox("Session Logging") {
            Toggle("Enable Logging", isOn: $loggingEnabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 4) {
                Text("Log Directory")
                HStack {
                    TextField("", text: $logDirectory, prompt: Text(defaultLogDirectory))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                    Button("…") {
                        chooseDirectory(prompt: "Select Log Directory",
                                        current: logDirectory.isEmpty ? defaultLogDirectory : logDirectory) { path in
                            logDirectory = path
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            Button("Open Log Directory") {
                if let logDir = SessionLogger.shared.logDirectoryURL {
                    NSWorkspace.shared.open(logDir)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Directory Helpers

    private var defaultDownloadDirectory: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return downloads?.appendingPathComponent("TERMinator").path ?? ""
    }

    private var defaultLogDirectory: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return appSupport?.appendingPathComponent("TERMinator/logs").path ?? ""
    }

    private func chooseDirectory(prompt: String, current: String, onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.prompt = "Select"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        panel.begin { response in
            if response == .OK, let url = panel.url {
                onPick(url.path)
            }
        }
    }

    // MARK: - Import/Export

    private var importExportSection: some View {
        sectionBox("Backup & Restore") {
            HStack(spacing: 12) {
                Button("Export Connections") {
                    exportConnections()
                }
                .buttonStyle(.bordered)

                Button("Import Connections") {
                    importConnections()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Help

    private var helpSection: some View {
        sectionBox("Help") {
            Button {
                showingHelp = true
            } label: {
                HStack {
                    Text("View Help")
                    Spacer()
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.textSecondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// Same flows as File > Export / Import Phonebook (Windows-matching .zip/.xml, merge-or-replace).
    private func exportConnections() {
        ImportExportManager.shared.runExportFlow()
    }

    private func importConnections() {
        ImportExportManager.shared.runImportFlow()
    }
}
