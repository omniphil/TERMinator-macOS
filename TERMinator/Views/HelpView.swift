import SwiftUI

/// Help view with comprehensive usage instructions for the macOS version.
/// Presented as a sheet from Settings or the Help menu.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Spacer()

                Text("TERMinator Help")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.termLightGreen)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.appPrimary)
                .font(.system(size: 13, design: .monospaced))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.surface)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Terminal Controls
                    helpSection(title: "Terminal Controls") {
                        helpSubsection(title: "Keyboard Shortcuts") {
                            Text("Standard keyboard input is sent directly to the BBS. Additional shortcuts:")
                            bulletPoint("Cmd+C / Cmd+V - Copy / Paste")
                            bulletPoint("Cmd+Return - Toggle Full Screen")
                            bulletPoint("Cmd+P - Open Phonebook")
                            bulletPoint("Cmd+D - Disconnect")
                            bulletPoint("Cmd+U - Send File (ZMODEM)")
                            bulletPoint("Cmd+, - Open Preferences")
                            bulletPoint("Esc, Tab, Ctrl+key - Sent directly to BBS")
                        }

                        helpSubsection(title: "Right-Click Menu") {
                            Text("Right-click anywhere on the terminal to access:")
                            bulletPoint("Paste Text - paste from clipboard")
                            bulletPoint("Show/Hide Cursor")
                            bulletPoint("Show/Hide Status Bar")
                            bulletPoint("Send File (ZMODEM) - upload a file")
                            bulletPoint("Capture Screenshot - save to disk")
                            bulletPoint("Save Thumbnail - set Phonebook image")
                            bulletPoint("Toggle Logging - record session")
                            bulletPoint("Disconnect - close connection")
                        }

                        helpSubsection(title: "Zoom") {
                            bulletPoint("Cmd+ (Cmd and Plus) to zoom in")
                            bulletPoint("Cmd- (Cmd and Minus) to zoom out")
                            bulletPoint("Cmd+0 to reset to 100%")
                            bulletPoint("Pinch gesture on trackpad also works")
                        }

                        helpSubsection(title: "Scrollback") {
                            bulletPoint("Scroll wheel or trackpad two-finger scroll to browse history")
                            bulletPoint("Scroll up to view previous output")
                            bulletPoint("Scroll down to return to the live session")
                        }

                        helpSubsection(title: "Clickable URLs") {
                            Text("Click URLs displayed on screen to open them in your default browser.")
                        }

                        helpSubsection(title: "Connection Status Bar") {
                            Text("Shows BBS name, connection time, screen mode, and data transfer stats. Can be toggled per-connection via the right-click menu.")
                        }
                    }

                    // Session Logging
                    helpSection(title: "Session Logging") {
                        helpSubsection(title: "Capture Session Transcript") {
                            bulletPoint("View menu > \"Toggle Logging\" while connected")
                            bulletPoint("Red \"REC\" indicator appears in the status bar")
                            bulletPoint("Toggle again to stop recording")
                            bulletPoint("Logs saved with BBS name and timestamp")
                            bulletPoint("Open log directory from Settings > Session Logging")
                        }
                    }

                    // File Transfer
                    helpSection(title: "File Transfer (ZMODEM)") {
                        helpSubsection(title: "Auto-Detection") {
                            Text("Downloads start automatically when the BBS initiates a ZMODEM transfer.")
                        }

                        helpSubsection(title: "Send File") {
                            bulletPoint("Start ZMODEM receive on the BBS first")
                            bulletPoint("Transfer menu > \"Send File...\" (Cmd+U)")
                            bulletPoint("Select a file from the file picker")
                            bulletPoint("File will upload automatically")
                        }

                        helpSubsection(title: "Receive File") {
                            bulletPoint("Usually auto-detected when the BBS sends")
                            bulletPoint("Saves to the app Documents folder")
                        }
                    }

                    // SSH Connections
                    helpSection(title: "SSH Connections") {
                        helpSubsection(title: "SSH Credentials") {
                            bulletPoint("Passwords are encrypted using macOS Keychain")
                            bulletPoint("Passwords are NOT exported with your BBS list")
                            bulletPoint("When editing, leave password empty to keep existing")
                        }
                    }

                    // Home Screen
                    helpSection(title: "Home Screen") {
                        helpSubsection(title: "Quick Connect Buttons") {
                            Text("Two customizable slots for instant connection to your favorite BBSes.")
                        }

                        helpSubsection(title: "Setting Quick Connect") {
                            Text("Click an empty Quick Connect slot to go to the Phonebook and choose a BBS.")
                        }

                        helpSubsection(title: "Connecting") {
                            Text("Double-click a Quick Connect slot to connect to that BBS.")
                        }
                    }

                    // Phonebook
                    helpSection(title: "Phonebook") {
                        helpSubsection(title: "View Modes") {
                            Text("Use the view mode buttons in the toolbar to switch between List, Small, Medium, and Large tile layouts.")
                        }

                        helpSubsection(title: "Edit/Delete") {
                            Text("Click a connection to open its edit sheet where you can modify settings or delete it.")
                        }

                        helpSubsection(title: "Thumbnails") {
                            Text("Snapshots taken during sessions appear as thumbnails in the tile views.")
                        }

                        helpSubsection(title: "Add New") {
                            Text("Click the \"+\" button in the Phonebook toolbar to add a new BBS entry.")
                        }
                    }

                    // Menu Bar
                    helpSection(title: "Menu Bar") {
                        helpSubsection(title: "File Menu") {
                            bulletPoint("Phonebook (Cmd+P) - open your BBS list")
                            bulletPoint("Disconnect (Cmd+D) - close current connection")
                        }

                        helpSubsection(title: "Transfer Menu") {
                            bulletPoint("Send File... (Cmd+U) - ZMODEM upload")
                            bulletPoint("Receive File - ZMODEM download")
                        }

                        helpSubsection(title: "View Menu") {
                            bulletPoint("Full Screen (Cmd+Return)")
                            bulletPoint("Toggle Logging")
                        }

                        helpSubsection(title: "Preferences") {
                            bulletPoint("Preferences (Cmd+,) - open settings")
                            bulletPoint("Clear TAP+ Cache - remove cached audio")
                        }
                    }

                    // Settings
                    helpSection(title: "Settings") {
                        helpSubsection(title: "Bell & Notifications") {
                            bulletPoint("Toggle sounds on or off")
                            bulletPoint("Choose from 30 vintage computer bell tones")
                            bulletPoint("Adjust volume with the slider")
                        }

                        helpSubsection(title: "TAP - Terminal Audio Protocol") {
                            bulletPoint("Enable/disable BBS background music")
                            bulletPoint("Manage audio cache size")
                        }

                        helpSubsection(title: "Backup & Restore") {
                            bulletPoint("Export/Import BBS connections list")
                            bulletPoint("Passwords are excluded for security")
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(Color.background)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 500, idealHeight: 650)
    }

    // MARK: - Helper Views

    private func helpSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.termLightGreen)

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.panelBorder, lineWidth: 1)
        )
    }

    private func helpSubsection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.appPrimary)

            content()
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
            Text(text)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(.textSecondary)
    }
}

// MARK: - Preview

struct HelpView_Previews: PreviewProvider {
    static var previews: some View {
        HelpView()
    }
}
