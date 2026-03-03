import SwiftUI

/// Main content view that switches between app screens.
/// Uses enum-based navigation (no NavigationStack) like Windows ContentControl.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var deepLinkManager: DeepLinkManager

    @State private var showingAbout = false
    @State private var showingHelp = false

    var body: some View {
        ZStack {
            // Dark background
            Color.background.ignoresSafeArea()

            // Content based on current navigation state
            switch appState.currentView {
            case .home:
                HomeView()

            case .phonebook:
                PhonebookView()

            case .terminal(let entry):
                TerminalView(entry: entry)

            case .settings:
                SettingsView()
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in
            showingAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in
            showingHelp = true
        }
        .onChange(of: deepLinkManager.pendingConnection) { connection in
            if let conn = connection {
                let entry = BBSEntry(
                    name: conn.name,
                    host: conn.host,
                    port: conn.port,
                    connectionProtocol: .telnet
                )
                appState.currentView = .terminal(entry)
                deepLinkManager.clearPending()
            }
        }
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingLicenses = false

    var body: some View {
        VStack(spacing: 16) {
            Text("TERMinator - BBS Terminal")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.termLightGreen)

            Text("v0.9.0 Beta")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.amberAccent)

            // Scrollable credits area (matches Windows 540x420 layout)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    creditsLine

                    Text("Credits")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    creditsLine

                    Spacer().frame(height: 6)

                    // SyncTERM attribution (matches Windows text)
                    Text("Based on SyncTERM, we would not exist without the legendary work of SyncTERM, so hats off to the SyncTERM folks!")
                        .aboutText()

                    Spacer().frame(height: 12)

                    // Developer credits
                    Text("macOS version by JSONBourne 2026")
                        .aboutText()
                    Text("JSONBourne Innovations")
                        .aboutText()
                    aboutLink("jsonbourneinnovations@gmail.com",
                              url: "mailto:jsonbourneinnovations@gmail.com")
                    aboutLink("deadmodemsociety.com",
                              url: "https://deadmodemsociety.com")

                    Spacer().frame(height: 12)

                    // aNSt credits
                    Text("Special thx to aNACHRONiST (aNSt) for the artwork and testing!")
                        .aboutText()
                    HStack(spacing: 0) {
                        Text("He may be reached at: ")
                            .aboutText()
                        aboutLink("aNSt@absinthebbs.net",
                                  url: "mailto:aNSt@absinthebbs.net")
                    }
                    Text("for collaborations and commissions")
                        .aboutText()

                    Spacer().frame(height: 12)

                    // License & GitHub
                    Text("This application is open source and licensed under the GNU GPL v2.")
                        .aboutText()
                    HStack(spacing: 0) {
                        Text("GitHub: ")
                            .aboutText()
                        aboutLink("github.com/omniphil/TERMinator-macOS",
                                  url: "https://github.com/omniphil/TERMinator-macOS")
                    }
                }
                .padding(16)
            }
            .frame(height: 420)

            // Button bar (matches Windows: Licenses left, OK right)
            HStack {
                Button("Open Source Licenses...") {
                    showingLicenses = true
                }

                Spacer()

                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .frame(width: 90)
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(Color.surface)
        .sheet(isPresented: $showingLicenses) {
            OpenSourceLicensesView()
        }
    }

    private var creditsLine: some View {
        Text(String(repeating: "\u{2500}", count: 40))
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func aboutLink(_ text: String, url: String) -> some View {
        if let linkURL = URL(string: url) {
            return AnyView(
                Link(text, destination: linkURL)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.amberAccent)
            )
        } else {
            return AnyView(
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.amberAccent)
            )
        }
    }
}

private extension Text {
    func aboutText() -> some View {
        self.font(.system(size: 12, design: .monospaced))
            .foregroundColor(.textPrimary)
    }
}

// MARK: - Open Source Licenses View

struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Open Source Licenses")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.termLightGreen)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("TERMinator includes the following open source software:")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.textPrimary)
                        .padding(.bottom, 16)

                    licenseEntry(
                        name: "SyncTERM 1.8b",
                        copyright: "Copyright 2007 Stephen Hurd",
                        license: "GNU GPL v2",
                        url: "syncterm.net",
                        fullURL: "https://syncterm.net"
                    )

                    licenseDivider

                    licenseEntry(
                        name: "cryptlib",
                        copyright: "Copyright 1992-2023 Peter Gutmann",
                        license: "Sleepycat License",
                        url: "cryptlib.com",
                        fullURL: "https://www.cryptlib.com"
                    )

                    licenseDivider

                    licenseEntry(
                        name: "libxmp 4.6.0",
                        copyright: "Copyright 1996-2024 Claudio Matsuoka & Hipolito Carraro Jr",
                        license: "MIT",
                        url: "github.com/libxmp/libxmp",
                        fullURL: "https://github.com/libxmp/libxmp"
                    )

                    licenseDivider

                    licenseEntry(
                        name: "LibVLC / LibVLCSharp / VideoLAN.LibVLC.Windows",
                        copyright: "Copyright VideoLAN",
                        license: "LGPL 2.1",
                        url: "code.videolan.org/videolan/LibVLCSharp",
                        fullURL: "https://code.videolan.org/videolan/LibVLCSharp"
                    )

                    licenseDivider

                    licenseEntry(
                        name: "NAudio",
                        copyright: "Copyright Mark Heath",
                        license: "MIT",
                        url: "github.com/naudio/NAudio",
                        fullURL: "https://github.com/naudio/NAudio"
                    )

                    licenseDivider

                    licenseEntry(
                        name: "CommunityToolkit.Mvvm",
                        copyright: "Copyright Microsoft",
                        license: "MIT",
                        url: "github.com/CommunityToolkit/dotnet",
                        fullURL: "https://github.com/CommunityToolkit/dotnet"
                    )

                    licenseDivider

                    licenseEntry(
                        name: "WpfAnimatedGif",
                        copyright: "Copyright Thomas Levesque",
                        license: "Apache 2.0",
                        url: "github.com/XamlAnimatedGif/WpfAnimatedGif",
                        fullURL: "https://github.com/XamlAnimatedGif/WpfAnimatedGif"
                    )

                    licenseDivider

                    licenseEntry(
                        name: "System.Security.Cryptography.ProtectedData",
                        copyright: "Copyright Microsoft / .NET Foundation",
                        license: "MIT",
                        url: "github.com/dotnet/runtime",
                        fullURL: "https://github.com/dotnet/runtime"
                    )
                }
                .padding()
            }
            .frame(height: 360)

            HStack {
                Spacer()
                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .frame(width: 90)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color.surface)
    }

    private func licenseEntry(name: String, copyright: String, license: String, url: String, fullURL: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.textPrimary)
            Text(copyright)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.textPrimary)
            Text("License: \(license)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.textPrimary)
            if let linkURL = URL(string: fullURL) {
                Link(url, destination: linkURL)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.amberAccent)
            }
        }
        .padding(.vertical, 8)
    }

    private var licenseDivider: some View {
        Text(String(repeating: "\u{2500}", count: 40))
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
    }
}
