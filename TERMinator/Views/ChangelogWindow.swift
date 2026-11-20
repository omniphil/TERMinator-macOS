import SwiftUI
import AppKit

/// The Changelog window (TERMinator menu > Changelog): the old About box's first half, no
/// buttons. Title "Changelog", 540 wide, height sized to content, centered on the main
/// window, not resizable; a 420-high scrolling text area with a 20 margin. Esc closes it.
///
/// A plain AppKit window rather than a SwiftUI `Window` scene for the same reason as
/// `CrtSettingsWindow`: a second scene would take the launch window on macOS 14.
enum ChangelogWindow {
    private static var controller: NSWindowController?

    static func show() {
        if let controller {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Changelog"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x2E/255.0, alpha: 1.0)
        window.isReleasedWhenClosed = false   // the controller outlives each close
        // Not inside ContentView, so it does not inherit its dark color scheme (see CrtSettingsWindow).
        window.appearance = NSAppearance(named: .darkAqua)

        let host = NSHostingView(rootView: ChangelogView(onClose: { close() }).preferredColorScheme(.dark))
        window.contentView = host
        // Height sized to content.
        window.setContentSize(host.fittingSize)

        // Centered on the main window (falls back to the screen center).
        if let main = WindowSizeManager.mainWindow {
            let frame = window.frame
            let origin = NSPoint(x: main.frame.midX - frame.width / 2,
                                 y: main.frame.midY - frame.height / 2)
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        controller?.window?.close()
    }
}

/// Content of the Changelog window; text comes from `AppInfo` so the About box, this window
/// and the console's `changelog` command never drift apart.
struct ChangelogView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // Colorized like the console's "changelog" command: the logo colors on the name,
                    // amber headers, green bullets.
                    (Text("TERM").foregroundColor(.termLightMagenta).bold()
                        + Text("inator").foregroundColor(.termLightCyan).bold()
                        + Text(" - BBS Terminal").foregroundColor(.textPrimary))
                        .changelogText()
                    Text("Version \(AppInfo.version)")
                        .foregroundColor(.textSecondary)
                        .changelogText()
                    blankLine
                    Text("\u{2500}\u{2500}\u{2500} What's New \u{2500}\u{2500}\u{2500}")
                        .foregroundColor(.amberAccent)
                        .bold()
                        .changelogText()
                    blankLine

                    ForEach(Array(AppInfo.changelogLines.enumerated()), id: \.offset) { _, line in
                        if line.isEmpty {
                            blankLine
                        } else if line.hasPrefix("v") {
                            Text(line)
                                .foregroundColor(.amberAccent)
                                .bold()
                                .changelogText()
                        } else if line.hasPrefix("\u{2022} ") {
                            (Text("\u{2022} ").foregroundColor(.amberAccent)
                                + Self.bulletText(String(line.dropFirst(2))))
                                .changelogText()
                        } else {
                            Text(line)
                                .foregroundColor(.tickerGreen)
                                .changelogText()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 500, height: 420)
            .padding(20)

            // Esc closes the window.
            Button("") { onClose() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .frame(width: 540)
        .background(Color.backgroundMedium)
        .onExitCommand { onClose() }
    }

    /// A bullet's text, all green (like Windows `MainWindow.MenuChangelog_Click`).
    private static func bulletText(_ text: String) -> Text {
        Text(text).foregroundColor(.tickerGreen)
    }

    private var blankLine: some View {
        Text(" ").foregroundColor(.textPrimary).changelogText()
    }
}

private extension Text {
    /// Font and wrapping only; each line sets its own color above (a plain `Text` with none
    /// set falls back to `textPrimary` through the environment).
    func changelogText() -> some View {
        self.font(.system(size: 12, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
    }
}
