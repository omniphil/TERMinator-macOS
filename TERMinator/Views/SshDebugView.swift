import SwiftUI
import AppKit

/// SSH connection debug log window — equivalent to Windows SshDebugWindow.xaml.
/// Shows the accumulated SSH authentication/connection log for diagnostics.
struct SshDebugView: View {
    let logText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("SSH Connection Debug Log")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

            ScrollView([.vertical, .horizontal]) {
                Text(logText.isEmpty ? "(no SSH debug log captured)" : logText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.termLightGreen)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.black)
            .overlay(
                Rectangle()
                    .stroke(Color.panelBorder, lineWidth: 1)
            )

            HStack {
                Spacer()
                Button("Copy to Clipboard") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(logText, forType: .string)
                }
                .buttonStyle(.bordered)

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .padding(10)
        .frame(width: 700, height: 500)
        .background(Color.background)
    }
}
