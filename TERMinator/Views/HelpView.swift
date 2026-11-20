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
                // Section for section, in order and wording, the Windows client's HelpWindow.xaml; only the
                // shortcuts, menu paths and storage that genuinely differ on a Mac are adapted.
                VStack(alignment: .leading, spacing: 24) {
                    helpSection(title: "Terminal Controls") {
                        helpSubsection(title: "Keyboard") {
                            bulletPoint("Standard keyboard input is sent straight to the BBS.")
                            bulletPoint("Cmd+C / Cmd+V - copy the selection / paste")
                            bulletPoint("Cmd+A - select the whole screen")
                            bulletPoint("Cmd+Option+Return - toggle full screen")
                            bulletPoint("Option+I - send the saved login")
                            bulletPoint("Cmd+Shift+S - save a screenshot; File > Take BBS Snapshot sets the phonebook image")
                            bulletPoint("Esc, Tab and Ctrl+key are sent to the BBS untouched")
                        }

                        helpSubsection(title: "Selection and URLs") {
                            bulletPoint("Drag with the mouse to select text.")
                            bulletPoint("Click a URL shown on screen to open it in your browser.")
                        }

                        helpSubsection(title: "Scrollback") {
                            bulletPoint("Scroll the wheel (or two fingers on the trackpad) up to browse the history, down to return to the live session.")
                            bulletPoint("A SCROLLBACK banner shows how many lines back you are.")
                        }

                        helpSubsection(title: "Status bar") {
                            bulletPoint("Shows the BBS name, connection time, screen mode and transfer stats.")
                        }
                    }

                    helpSection(title: "CRT and Scanline Effects") {
                        helpSubsection(title: "Turning it on") {
                            bulletPoint("View menu > CRT / Scanline Effect... then tick Enable CRT effect.")
                            bulletPoint("The window is modeless: leave it open and dial the look in against live ANSI art.")
                            bulletPoint("Twelve presets, from Subtle Scanlines to Worn Out Tube.")
                            bulletPoint("RESET restores the factory look and leaves the on/off switch alone.")
                        }
                    }

                    helpSection(title: "Session Logging") {
                        helpSubsection(title: "Recording a transcript") {
                            bulletPoint("Call > Log Session while connected. It stays ticked while a transcript is being written.")
                            bulletPoint("Untick it to stop.")
                            bulletPoint("Logs are named after the BBS and the time, in the folder set in Preferences.")
                        }
                    }

                    helpSection(title: "File Transfer") {
                        helpSubsection(title: "ZMODEM") {
                            bulletPoint("Downloads start on their own when the BBS begins a ZMODEM send.")
                            bulletPoint("To upload: start the receive on the BBS first, then Transfer > Send File... (Cmd+U).")
                        }

                        helpSubsection(title: "XMODEM / YMODEM") {
                            bulletPoint("Nothing is auto-detected. Start the transfer on the BBS first, then pick the SAME protocol here.")
                            bulletPoint("Transfer > Send File via - XMODEM (128-byte), XMODEM (1K), YMODEM.")
                            bulletPoint("Transfer > Receive File via - XMODEM, YMODEM, YMODEM-G.")
                            bulletPoint("XMODEM carries no filename, so a receive asks where to save before it starts.")
                            bulletPoint("128-byte blocks are listed first because many 8-bit boards accept nothing else.")
                        }
                    }

                    helpSection(title: "Phonebook") {
                        helpSubsection(title: "Managing connections") {
                            bulletPoint("File > Phonebook (Cmd+P) opens your BBS list.")
                            bulletPoint("Drag a tile to reorder the list.")
                            bulletPoint("Snapshots taken during a session appear as the tile thumbnail.")
                            bulletPoint("Switch between List, Small, Medium and Large layouts from the toolbar.")
                        }

                        // Same wording as Windows HelpWindow.xaml (File menu items; ImportExportManager does the .zip
                        // itself, no ZIP library). Preferences > Backup & Restore runs the same two flows.
                        helpSubsection(title: "Import and export") {
                            bulletPoint("File > Export Phonebook... writes a .zip of your connections and their snapshots, or a plain .xml.")
                            bulletPoint("File > Import Phonebook... reads either back, and asks whether to merge or replace.")
                            bulletPoint("The format is shared with the Windows and Linux clients.")
                            bulletPoint("Passwords are NEVER exported - they stay in the macOS Keychain.")
                        }
                    }

                    helpSection(title: "Connections") {
                        helpSubsection(title: "Protocols") {
                            bulletPoint("Telnet, Raw, SSH, Telnet over SSL, and WebSocket (plain or secure).")
                            bulletPoint("Raw is a plain 8-bit socket with no telnet negotiation.")
                        }

                        helpSubsection(title: "Credentials") {
                            bulletPoint("Saved passwords are held in the macOS Keychain, not the phonebook.")
                            bulletPoint("Leave the password blank when editing to keep the existing one.")
                            bulletPoint("Call > Show SSH Debug Log shows the negotiation log after a failed SSH connection.")
                        }
                    }

                    helpSection(title: "Settings") {
                        helpSubsection(title: "Preferences") {
                            bulletPoint("Bell sound: pick from 30 vintage tones, or switch it off.")
                            bulletPoint("Terminal: default font and screen mode for new connections.")
                            bulletPoint("TAP+: BBS background music, and the audio cache limit.")
                            bulletPoint("File transfer: download folder and ZMODEM auto-detect.")
                            bulletPoint("Session logging: where transcripts are written.")
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
