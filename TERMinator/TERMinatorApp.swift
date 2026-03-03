import SwiftUI

/// Manages deep link (telnet:// URL) connections
class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    @Published var pendingConnection: QuickConnection?

    struct QuickConnection: Identifiable, Equatable {
        let id = UUID()
        let host: String
        let port: Int
        let name: String

        static func == (lhs: QuickConnection, rhs: QuickConnection) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Parse a telnet:// URL and create a quick connection
    func handleURL(_ url: URL) {
        guard url.scheme == "telnet" else { return }

        let host = url.host ?? ""
        let port = url.port ?? 23

        guard !host.isEmpty else { return }

        pendingConnection = QuickConnection(
            host: host,
            port: port,
            name: "Quick Connect"
        )
    }

    /// Clear the pending connection after handling
    func clearPending() {
        pendingConnection = nil
    }
}

/// Navigation state for the app
enum NavigationDestination: Hashable {
    case home
    case phonebook
    case terminal(BBSEntry)
    case settings
}

/// App-wide state
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var currentView: NavigationDestination = .home
    @Published var connectedEntry: BBSEntry?
    @Published var isConnected: Bool = false
    @Published var showTapPlus: Bool = true

    private init() {}
}

@main
struct TERMinatorApp: App {
    @StateObject private var deepLinkManager = DeepLinkManager.shared
    @StateObject private var appState = AppState.shared

    init() {
        // Initialize native bridge
        let filesDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        NativeBridge.shared.setFilesDir(filesDir)

        // Restore window size on next run cycle
        DispatchQueue.main.async {
            WindowSizeManager.restoreWindowSize()
        }

        // Save window size on quit
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            WindowSizeManager.saveWindowSize()
        }
    }

    var body: some Scene {
        WindowGroup("TERMinator v0.9.0 Beta") {
            ContentView()
                .environmentObject(deepLinkManager)
                .environmentObject(appState)
                .onOpenURL { url in
                    deepLinkManager.handleURL(url)
                }
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1024, height: 768)
        .commands {
            // File Menu
            CommandGroup(replacing: .newItem) {
                Button("Phonebook") {
                    appState.currentView = .phonebook
                }
                .keyboardShortcut("p")

                Divider()

                Button("Disconnect") {
                    if appState.isConnected {
                        NativeBridge.shared.disconnect()
                        appState.isConnected = false
                        appState.connectedEntry = nil
                        appState.currentView = .home
                    }
                }
                .keyboardShortcut("d")
                .disabled(!appState.isConnected)
            }

            // Edit Menu - keep defaults (Copy, Paste, Select All)

            // Transfer Menu
            CommandMenu("Transfer") {
                Button("Send File...") {
                    NotificationCenter.default.post(name: .sendFileRequested, object: nil)
                }
                .keyboardShortcut("u")
                .disabled(!appState.isConnected)

                Button("Receive File") {
                    NotificationCenter.default.post(name: .receiveFileRequested, object: nil)
                }
                .disabled(!appState.isConnected)
            }

            // View Menu (matches Windows: Full Screen, Show TAP+, Toggle Logging)
            CommandMenu("View") {
                Button("Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut(.return, modifiers: [.command, .option])

                Toggle("Show TAP+", isOn: $appState.showTapPlus)

                Button("Toggle Logging") {
                    NotificationCenter.default.post(name: .toggleLogging, object: nil)
                }
                .disabled(!appState.isConnected)

                Divider()

                Button("Zoom In") {
                    // Handled by keyboard shortcut in TerminalKeyboardView
                }
                .keyboardShortcut("=")
                .disabled(!appState.isConnected)

                Button("Zoom Out") {
                    // Handled by keyboard shortcut in TerminalKeyboardView
                }
                .keyboardShortcut("-")
                .disabled(!appState.isConnected)

                Button("Actual Size") {
                    // Handled by keyboard shortcut in TerminalKeyboardView
                }
                .keyboardShortcut("0")
                .disabled(!appState.isConnected)

                Divider()

                Button("Save Screenshot...") {
                    NotificationCenter.default.post(name: .captureScreenshot, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appState.isConnected)

                Button("Update Thumbnail") {
                    NotificationCenter.default.post(name: .saveSnapshot, object: nil)
                }
                .disabled(!appState.isConnected)
            }

            // Settings Menu
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    appState.currentView = .settings
                }
                .keyboardShortcut(",")

                Button("Clear TAP+ Cache") {
                    SoundtrackManager.shared.clearCache()
                }
            }

            // Help Menu
            CommandGroup(replacing: .help) {
                Button("TERMinator Help") {
                    NotificationCenter.default.post(name: .showHelp, object: nil)
                }
                .keyboardShortcut("?")

                Divider()

                Button("About TERMinator") {
                    NotificationCenter.default.post(name: .showAbout, object: nil)
                }
            }
        }
    }
}

// MARK: - Window Size Persistence

enum WindowSizeManager {
    private static let widthKey = "window_width"
    private static let heightKey = "window_height"
    private static let xKey = "window_x"
    private static let yKey = "window_y"

    static func saveWindowSize() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let frame = window.frame
        UserDefaults.standard.set(Double(frame.width), forKey: widthKey)
        UserDefaults.standard.set(Double(frame.height), forKey: heightKey)
        UserDefaults.standard.set(Double(frame.origin.x), forKey: xKey)
        UserDefaults.standard.set(Double(frame.origin.y), forKey: yKey)
    }

    static func restoreWindowSize() {
        let width = UserDefaults.standard.double(forKey: widthKey)
        let height = UserDefaults.standard.double(forKey: heightKey)
        guard width >= 800, height >= 600 else { return }  // Only restore if valid

        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let x = UserDefaults.standard.double(forKey: xKey)
        let y = UserDefaults.standard.double(forKey: yKey)

        var frame = NSRect(x: x, y: y, width: width, height: height)

        // Ensure window is on-screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            if !screenFrame.intersects(frame) {
                frame.origin = screenFrame.origin
            }
        }

        window.setFrame(frame, display: true)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let sendFileRequested = Notification.Name("sendFileRequested")
    static let receiveFileRequested = Notification.Name("receiveFileRequested")
    static let toggleLogging = Notification.Name("toggleLogging")
    static let showAbout = Notification.Name("showAbout")
    static let showHelp = Notification.Name("showHelp")
    static let captureScreenshot = Notification.Name("captureScreenshot")
    static let saveSnapshot = Notification.Name("saveSnapshot")
}
