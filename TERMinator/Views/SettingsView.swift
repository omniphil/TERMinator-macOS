import SwiftUI

/// Desktop-optimized settings view.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    // Bell Settings
    @ObservedObject private var bellManager = BellManager.shared

    // Soundtrack Settings
    @AppStorage(SoundtrackManager.keySoundtrackEnabled) private var soundtrackEnabled = true
    @AppStorage(SoundtrackManager.keySoundtrackCacheLimit) private var soundtrackCacheLimit = 100
    @ObservedObject private var soundtrackManager = SoundtrackManager.shared

    // Terminal Settings
    @AppStorage("default_font") private var defaultFontRaw: Int = TerminalFont.cp437.rawValue
    @AppStorage("default_screen_mode") private var defaultScreenModeRaw: Int = ScreenMode.mode80x25.rawValue

    // File Transfer Settings
    @AppStorage("auto_detect_zmodem") private var autoDetectZmodem = true

    // Logging Settings
    @AppStorage("logging_enabled") private var loggingEnabled = false

    // Alert state
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    // Help sheet state
    @State private var showingHelp = false

    var body: some View {
        VStack(spacing: 0) {
            // Content
            ScrollView {
                VStack(spacing: 0) {
                    // Inline toolbar: back button + title
                    HStack {
                        Button {
                            appState.currentView = .home
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Home")
                            }
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.amberAccent)

                        Spacer()

                        Text("SETTINGS")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.accentGreen)

                        Spacer()
                        Color.clear.frame(width: 60)
                    }
                    .padding(.bottom, 4)

                    bellSettingsSection
                    terminalSettingsSection
                    soundtrackSettingsSection
                    fileTransferSettingsSection
                    loggingSettingsSection
                    importExportSection
                    helpSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(Color.background)
        .alert(alertTitle, isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
    }

    // MARK: - Section Header Helper

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.amberAccent)
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
                    Slider(value: $bellManager.volume, in: 0...1)
                    Text("\(Int(bellManager.volume * 100))%")
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

    // MARK: - File Transfer Settings

    private var fileTransferSettingsSection: some View {
        sectionBox("File Transfer") {
            Toggle("Auto-Detect ZMODEM", isOn: $autoDetectZmodem)
                .toggleStyle(.switch)

            HStack {
                Text("Download Directory")
                Spacer()
                Button("Choose...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Select"
                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            UserDefaults.standard.set(url.path, forKey: "download_directory")
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            if let downloadDir = UserDefaults.standard.string(forKey: "download_directory") {
                Text(downloadDir)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    // MARK: - Logging Settings

    private var loggingSettingsSection: some View {
        sectionBox("Session Logging") {
            Toggle("Enable Logging", isOn: $loggingEnabled)
                .toggleStyle(.switch)

            Button("Open Log Directory") {
                if let logDir = SessionLogger.shared.logDirectoryURL {
                    NSWorkspace.shared.open(logDir)
                }
            }
            .buttonStyle(.bordered)
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

    private func exportConnections() {
        guard let url = ImportExportManager.shared.exportConnections() else {
            alertTitle = "Export Failed"
            alertMessage = "No connections to export or an error occurred."
            showingAlert = true
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.xml]
        savePanel.nameFieldStringValue = url.lastPathComponent
        savePanel.begin { response in
            if response == .OK, let destURL = savePanel.url {
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: url, to: destURL)
                    alertTitle = "Export Successful"
                    alertMessage = "Connections exported to \(destURL.lastPathComponent)."
                    showingAlert = true
                } catch {
                    alertTitle = "Export Failed"
                    alertMessage = error.localizedDescription
                    showingAlert = true
                }
            }
        }
    }

    private func importConnections() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.xml]
        openPanel.allowsMultipleSelection = false
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                let count = ImportExportManager.shared.importConnections(from: url, replace: false)
                if count > 0 {
                    alertTitle = "Import Successful"
                    alertMessage = "Imported \(count) connection(s)."
                } else if count == 0 {
                    alertTitle = "Import Complete"
                    alertMessage = "No new connections found in the file."
                } else {
                    alertTitle = "Import Failed"
                    alertMessage = "Could not read the selected file."
                }
                showingAlert = true
            }
        }
    }
}
