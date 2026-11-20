import SwiftUI
import AppKit

/// Help > Check for Updates (Windows `Views/UpdateWindow.cs`): checking, then up to date / an error / the
/// new version's notes with Download & Install, then the download progress, then Quit & Install (macOS: the app is
/// sandboxed, so the user drags the new TERMinator onto Applications; see `UpdateService`). Same text sizes as
/// Windows: 22 heading, 16 text, 15 buttons, 560 wide.
///
/// A plain AppKit window rather than a SwiftUI `Window` scene, like `ChangelogWindow`.
@MainActor
enum UpdateWindow {
    private static var controller: NSWindowController?
    private static var model: UpdateModel?

    static func show() {
        if let controller, controller.window?.isVisible == true {
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Check for Updates"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x2E/255.0, alpha: 1.0)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)

        let model = UpdateModel(onClose: { close() }, onResize: { resize() })
        self.model = model
        let host = NSHostingView(rootView: UpdateView(model: model).preferredColorScheme(.dark))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        center(window)

        let controller = NSWindowController(window: window)
        self.controller = controller
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { UpdateWindow.model?.cancel() }
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        model.start()
    }

    static func close() {
        controller?.window?.close()
    }

    /// The content changed size between steps: fit the window to it, keeping its top edge where it was.
    private static func resize() {
        guard let window = controller?.window, let host = window.contentView else { return }
        let top = window.frame.maxY
        window.setContentSize(host.fittingSize)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    private static func center(_ window: NSWindow) {
        if let main = WindowSizeManager.mainWindow, main.isVisible, !main.isMiniaturized {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: main.frame.midX - size.width / 2, y: main.frame.midY - size.height / 2))
        } else {
            window.center()
        }
    }
}

@MainActor
final class UpdateModel: ObservableObject {
    enum Phase {
        case checking
        case upToDate
        case checkFailed(String)
        case available(UpdateInfo)
        case downloading(UpdateInfo, Double)
        case downloadFailed(String)
        case ready(UpdateInfo, URL)
        case openFailed(URL)
    }

    @Published var phase: Phase = .checking {
        didSet { DispatchQueue.main.async { [onResize] in onResize() } }
    }
    let onClose: () -> Void
    private let onResize: () -> Void
    private var task: Task<Void, Never>?

    init(onClose: @escaping () -> Void, onResize: @escaping () -> Void) {
        self.onClose = onClose
        self.onResize = onResize
    }

    func start() {
        task = Task { [weak self] in
            do {
                let info = try await UpdateService.check()
                guard let self, !Task.isCancelled else { return }
                self.phase = UpdateService.isNewer(info.version, than: UpdateService.currentVersion)
                    ? .available(info) : .upToDate
            } catch is CancellationError {
            } catch {
                self?.phase = .checkFailed(error.localizedDescription)
            }
        }
    }

    func download(_ info: UpdateInfo) {
        phase = .downloading(info, 0)
        task = Task { [weak self] in
            do {
                let dmg = try await UpdateService.download(info) { fraction in
                    if let self, case .downloading = self.phase { self.phase = .downloading(info, fraction) }
                }
                guard let self, !Task.isCancelled else { return }
                self.phase = .ready(info, dmg)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .downloadFailed(error.localizedDescription)
            }
        }
    }

    func install(_ dmg: URL) {
        if !UpdateService.openInstallerAndQuit(dmg) {
            phase = .openFailed(dmg)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// What installing would interrupt (Windows `MainWindow.MenuCheckUpdates_Click`), or nil.
    var hangUpWarning: String? {
        let windows = SessionLauncher.openSessions.count
        if AppState.shared.isConnected {
            return windows > 0 ? "Installing hangs up this call and closes your BBS windows." : "Installing hangs up this call."
        }
        if windows > 0 {
            return windows == 1 ? "Installing closes your open BBS window and hangs up its call."
                                : "Installing closes your \(windows) open BBS windows and hangs up their calls."
        }
        return nil
    }
}

struct UpdateView: View {
    @ObservedObject var model: UpdateModel

    private var current: String { UpdateService.currentVersion }

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .checking:
                heading("Checking for updates...")
                line("You have version \(current).")

            case .upToDate:
                heading("You're up to date", color: .accentGreen)
                line("Version \(current) is the latest.")
                buttons { button("OK", style: .green, isDefault: true) { model.onClose() } }

            case .checkFailed(let reason):
                heading("Couldn't check for updates", color: .accentRed)
                line(reason)
                buttons { button("CLOSE", style: .green, isDefault: true) { model.onClose() } }

            case .available(let info):
                heading("Version \(info.version) is available")
                line("You have \(current). Download size \(String(format: "%.1f", Double(info.size) / 1048576.0)) MB.")
                if !info.notes.isEmpty {
                    notes(info.notes)
                }
                if let warning = model.hangUpWarning {
                    Text(warning)
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundColor(.accentRed)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                buttons {
                    button("DOWNLOAD & INSTALL", style: .amber, isDefault: true) { model.download(info) }
                    button("LATER", style: .green, isCancel: true) { model.onClose() }
                }

            case .downloading(let info, let fraction):
                heading("Downloading \(info.version)...")
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.amberAccent)
                    .padding(.top, 14)
                Text(String(format: "%.0f%%  (%.1f of %.1f MB)", fraction * 100,
                            fraction * Double(info.size) / 1048576.0, Double(info.size) / 1048576.0))
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .padding(.top, 6)
                buttons { button("CANCEL", style: .green, isCancel: true) { model.onClose() } }

            case .downloadFailed(let reason):
                heading("The download failed", color: .accentRed)
                line(reason)
                buttons { button("CLOSE", style: .green, isDefault: true) { model.onClose() } }

            case .ready(let info, let dmg):
                heading("Ready to install \(info.version)")
                line("TERMinator will quit and open the installer. Drag TERMinator onto the Applications folder and choose Replace.")
                buttons {
                    button("QUIT & INSTALL", style: .amber, isDefault: true) { model.install(dmg) }
                    button("LATER", style: .green, isCancel: true) { model.onClose() }
                }

            case .openFailed(let dmg):
                heading("Couldn't open the installer", color: .accentRed)
                line("It's saved as \(dmg.path). Quit TERMinator, open it, and drag TERMinator onto Applications.")
                buttons { button("CLOSE", style: .green, isDefault: true) { model.onClose() } }
            }
        }
        .padding(EdgeInsets(top: 30, leading: 36, bottom: 26, trailing: 36))
        .frame(width: 560)
        .background(Color.surface)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { model.onClose() }
    }

    private func heading(_ text: String, color: Color = .amberAccent) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, design: .monospaced))
            .foregroundColor(.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    private func notes(_ notes: [String]) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\u{2500}\u{2500}\u{2500} What's New \u{2500}\u{2500}\u{2500}")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.amberAccent)
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    (Text("\u{2022} ").foregroundColor(.amberAccent) + Text(note).foregroundColor(.tickerGreen))
                        .font(.system(size: 16, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.notesHeight(notes))
        .padding(.top, 14)
    }

    /// The notes' height, up to 300 (then they scroll). Estimated, because the window sizes itself to its content
    /// and a ScrollView has no useful height of its own: 16 pt monospaced is ~9.6 pt a character, ~50 to a line.
    private static func notesHeight(_ notes: [String]) -> CGFloat {
        let lines = notes.reduce(1) { $0 + max(1, ($1.count + 2 + 49) / 50) }
        return min(300, CGFloat(lines) * 21 + 4)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.top, 18)
    }

    /// A RetroButton at 15 pt (its own 13 is small next to this window's text, as on Windows).
    @ViewBuilder
    private func button(_ title: String, style: RetroButtonPreset, isDefault: Bool = false, isCancel: Bool = false,
                        action: @escaping () -> Void) -> some View {
        let b = Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .buttonStyle(RetroButtonStyle(fgColor: style.fg, borderColor: style.border, hoverBgColor: style.hoverBg))
        if isDefault {
            b.keyboardShortcut(.defaultAction)
        } else if isCancel {
            b.keyboardShortcut(.cancelAction)
        } else {
            b
        }
    }
}
