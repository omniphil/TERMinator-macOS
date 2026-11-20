import AppKit
import SwiftUI

/// Command line mode (spec §6): a full-window console above everything, `#050508` ground, content
/// margin 36,28, monospaced 15, output above an input line that carries the `TERMinator> ` prompt in
/// the home logo's CGA bright magenta / bright cyan. Mirrors the Windows client's
/// `Controls/CommandLineOverlay.cs`; the interpreter lives in `CommandLineConsole`.
///
/// Everything drawn is pure SwiftUI, because it all goes through `.screenEffect` and SwiftUI's shader
/// effects only draw SwiftUI's own rendering: an AppKit-backed view inside one comes out blank. CRT
/// mode's `layerEffect` used to leave the whole console black — SwiftUI's `ScrollView` is an
/// `NSScrollView` on macOS, and the input line was an `NSTextField`. So the output scrolls by hand
/// (`scrollback`, a scroll-wheel monitor) and the input line is drawn (`ConsoleInputLine`) from what
/// an invisible AppKit field (`ConsoleInputField`) outside the effect holds. That field keeps the
/// keyboard: Tab, the arrows and Ctrl+C / Ctrl+L never reach a SwiftUI `TextField`.
///
/// Clicking anywhere puts the keyboard back in the input line.
struct CommandLineView: View {
    @ObservedObject var console: CommandLineConsole
    /// The console's screen effect (spec §7): the full CRT effect with the terminal's settings while
    /// CRT mode is on, tinted with the phosphor color if one is set; otherwise the phosphor tint
    /// alone, or nothing in Color mode. Both stores publish, so a change from the CRT window, the
    /// View menu or the console's own `crt` / `phosphor` commands shows at once.
    @ObservedObject private var crtStore = CrtSettingsStore.shared
    @AppStorage(AppPreferences.phosphor) private var phosphor = PhosphorMode.color.rawValue

    /// IBM Model M clicks for the console's keystrokes. A watcher, not a key handler: the AppKit field keeps
    /// every key; this only listens (it never swallows).
    @State private var clickKeys = KeyEventMonitor()
    /// The scroll wheel / trackpad, which no scroll view is there to take.
    @State private var wheel = ScrollWheelMonitor()
    /// The hidden field's text and selection. `@State`, not `@StateObject`: only `ConsoleInputLine`
    /// observes it, so a keystroke doesn't re-render a thousand output lines.
    @State private var echo = ConsoleInputEcho()

    /// Points scrolled back up from the bottom; 0 follows the output.
    @State private var scrollback: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    fileprivate static let font = Font.system(size: 15, design: .monospaced)
    /// A wheel click (no precise deltas) scrolls about a line.
    private static let wheelLine: CGFloat = 18

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Takes the keys: outside the screen effect, a point square with clear text and caret,
            // under the opaque screen.
            ConsoleInputField(console: console, echo: echo)
                .frame(width: 1, height: 1)

            screen
                .screenEffect(crt: crtStore.current, phosphor: PhosphorMode(rawValue: phosphor) ?? .color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Clicking anywhere focuses the input line.
        .onTapGesture {
            console.focusInput()
        }
        .onHover { inside in
            if inside {
                NSCursor.iBeam.push()
            } else {
                NSCursor.pop()
            }
        }
        // Every write brings the output back to the bottom, and so does typing.
        .onChange(of: console.scrollTick) { _ in
            scrollback = 0
        }
        .onReceive(echo.$text.removeDuplicates().dropFirst()) { _ in
            if scrollback != 0 {
                scrollback = 0
            }
        }
        .onAppear {
            console.focusInput()
            // A click per real keypress: key-downs only (bare modifiers never produce one), not auto-repeat,
            // and not while the boot sequence is typing (the input line is hidden then). ⌘ keys pass untouched.
            let console = self.console
            clickKeys.start { event in
                // The Boss Hide keys (⌃⇧B, F15) never click, whichever key monitor AppKit runs first
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let bossChord = (modifiers == [.control, .shift] && event.charactersIgnoringModifiers?.lowercased() == "b")
                    || event.keyCode == 113
                if console.isVisible && console.bootScreen == nil && !event.isARepeat && !bossChord {
                    KeyClickService.shared.play(space: event.keyCode == 49)
                }
                return false
            }
            // Scrolling in the main window scrolls the output, and nothing under the console.
            wheel.start { event in
                guard console.isVisible, event.window === WindowSizeManager.mainWindow,
                      !AppState.shared.bossHideActive else { return false }
                let delta = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY
                    : event.scrollingDeltaY * Self.wheelLine
                scrollback = min(max(0, scrollback + delta), maxScrollback)
                return true
            }
        }
        .onDisappear {
            clickKeys.stop()
            wheel.stop()
        }
    }

    // MARK: - Screen

    /// The drawn console: output and input line, top-aligned until it overflows, then pinned to the
    /// bottom less `scrollback`.
    private var screen: some View {
        ZStack(alignment: .topLeading) {
            Color.deepBlack

            GeometryReader { geometry in
                output
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: geometry.size.width, alignment: .topLeading)
                    .background(GeometryReader { content in
                        Color.clear.preference(key: ContentHeightKey.self, value: content.size.height)
                    })
                    .offset(y: min(scrollback, maxScrollback) - maxScrollback)
                    .preference(key: ViewportHeightKey.self, value: geometry.size.height)
            }
            .clipped()
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }

            // Windows: the ScrollViewer's bar, shown only when the output overflows (Auto)
            if maxScrollback > 0 {
                ConsoleScrollBar(scrollback: $scrollback, content: contentHeight, viewport: viewportHeight)
                    .frame(width: ConsoleScrollBar.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
    }

    private var maxScrollback: CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    private var output: some View {
        ConsoleOutput(console: console, echo: echo)
    }

    /// `TERMinator> ` — "TERM" bright magenta, "inator" and "> " bright cyan, all bold: the home
    /// logo's own colors, solid (no gradient).
    fileprivate static var promptText: Text {
        Text("TERM").foregroundColor(.termLightMagenta).bold()
            + Text("inator").foregroundColor(.termLightCyan).bold()
            + Text("> ").foregroundColor(.termLightCyan).bold()
    }
}

/// The console's lines and input line (or the boot screen). Its own view so that scrolling — a `@State` change in
/// `CommandLineView` — only moves it rather than rebuilding up to a thousand lines.
private struct ConsoleOutput: View {
    @ObservedObject var console: CommandLineConsole
    let echo: ConsoleInputEcho

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(console.lines) { line in
                lineView(line)
            }

            // "boot" types into the console with the input line hidden (keys ignored).
            if let screen = console.bootScreen {
                Text(screen)
                    .font(CommandLineView.font)
                    .foregroundColor(.tickerGreen)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ConsoleInputLine(echo: echo)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 28, leading: 36, bottom: 28, trailing: 36))
    }

    @ViewBuilder
    private func lineView(_ line: CommandLineConsole.Line) -> some View {
        if line.isPrompt {
            (CommandLineView.promptText + Text(line.text).foregroundColor(.tickerGreen))
                .font(CommandLineView.font)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // An empty line still has to take a line's height, as the WPF TextBlock does.
            Text(line.text.isEmpty ? " " : line.text)
                .font(CommandLineView.font)
                .foregroundColor(line.style.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The console's scroll bar, drawn in SwiftUI (so the screen effect reaches it) after Windows' RetroTheme bar:
/// 12 pt on the dark ground, an 8 pt rounded thumb (#555566, #777788 hovered, #999999 dragged), and a click on
/// the track pages by a screenful. `scrollback` is points up from the bottom, as `CommandLineView` keeps it.
private struct ConsoleScrollBar: View {
    @Binding var scrollback: CGFloat
    let content: CGFloat
    let viewport: CGFloat

    static let width: CGFloat = 12
    private static let minThumb: CGFloat = 24

    @State private var hovered = false
    /// Where in the thumb the drag took hold, or nil when the press started on the track.
    @State private var grab: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let track = geometry.size.height
            let maxScrollback = max(1, content - viewport)
            let thumb = min(track, max(Self.minThumb, track * viewport / max(content, 1)))
            let travel = max(0, track - thumb)
            let top = travel * (1 - min(max(scrollback, 0), maxScrollback) / maxScrollback)

            ZStack(alignment: .topLeading) {
                Color.background

                RoundedRectangle(cornerRadius: 4)
                    .fill(thumbColor)
                    .frame(width: Self.width - 4, height: thumb)
                    .offset(x: 2, y: top)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if grab == nil {
                            let y = value.startLocation.y
                            if y >= top && y <= top + thumb {
                                grab = y - top
                            } else {
                                // Track click: a page toward the click, as WPF's page buttons
                                grab = -1
                                let page = max(viewport - 16, 16)
                                scrollback = y < top ? min(scrollback + page, maxScrollback)
                                                     : max(scrollback - page, 0)
                                return
                            }
                        }
                        guard let grab = grab, grab >= 0, travel > 0 else { return }
                        let newTop = min(max(value.location.y - grab, 0), travel)
                        scrollback = maxScrollback * (1 - newTop / travel)
                    }
                    .onEnded { _ in
                        grab = nil
                    }
            )
            .onHover { inside in
                hovered = inside
                if inside {
                    NSCursor.arrow.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }

    private var thumbColor: Color {
        if let grab = grab, grab >= 0 {
            return Color(red: 0x99 / 255.0, green: 0x99 / 255.0, blue: 0x99 / 255.0)
        }
        return hovered ? Color(red: 0x77 / 255.0, green: 0x77 / 255.0, blue: 0x88 / 255.0)
                       : Color(red: 0x55 / 255.0, green: 0x55 / 255.0, blue: 0x66 / 255.0)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A local scroll-wheel monitor. The handler returns true to swallow the event.
private final class ScrollWheelMonitor {
    private var monitor: Any?

    func start(_ handler: @escaping (NSEvent) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handler(event) ? nil : event
        }
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        stop()
    }
}

// MARK: - The input line

/// What the hidden input field holds, for the drawn input line.
final class ConsoleInputEcho: ObservableObject {
    @Published private(set) var text = ""
    /// UTF-16, as the field editor reports it.
    @Published private(set) var selection = NSRange(location: 0, length: 0)
    /// The caret's blink restarts here, so it stays lit while typing.
    private(set) var changedAt = Date()

    func update(text: String, selection: NSRange) {
        guard text != self.text || selection != self.selection else { return }
        changedAt = Date()
        self.text = text
        self.selection = selection
    }

    /// The text before the selection (or caret), the selection, and the text after it.
    var parts: (before: String, selected: String, after: String) {
        let string = text as NSString
        let start = min(max(0, selection.location), string.length)
        let end = min(start + max(0, selection.length), string.length)
        return (string.substring(to: start),
                string.substring(with: NSRange(location: start, length: end - start)),
                string.substring(from: end))
    }
}

/// The drawn input line: the prompt, the typed text (`#55DD55`, spec §6) with any selection, and a
/// blinking caret, scrolled sideways to keep the caret in view once the line outgrows the window.
private struct ConsoleInputLine: View {
    @ObservedObject var echo: ConsoleInputEcho
    /// The caret only blinks while the window is key, as a real field's does.
    @Environment(\.controlActiveState) private var activeState

    @State private var width: CGFloat = 0

    private static let measureFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private static let caretHeight: CGFloat = 18
    private static let blink: TimeInterval = 0.5

    var body: some View {
        let parts = echo.parts
        // Centered rather than baseline-aligned, as the AppKit field used to be.
        return HStack(alignment: .center, spacing: 0) {
            CommandLineView.promptText
                .font(CommandLineView.font)
                .fixedSize()

            typed(parts)
                .fixedSize()
                .offset(x: -sidewaysScroll(before: parts.before))
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: InputWidthKey.self, value: geometry.size.width)
                })
                .onPreferenceChange(InputWidthKey.self) { width = $0 }
        }
        .padding(.top, 2)
    }

    private func typed(_ parts: (before: String, selected: String, after: String)) -> some View {
        HStack(spacing: 0) {
            Text(parts.before)
            if parts.selected.isEmpty {
                caret
            } else {
                Text(parts.selected)
                    .background(Color.tickerGreen.opacity(0.35))
            }
            Text(parts.after)
        }
        .font(CommandLineView.font)
        .foregroundColor(.tickerGreen)
    }

    /// Zero-width, so the text doesn't move as it blinks.
    private var caret: some View {
        TimelineView(.periodic(from: echo.changedAt, by: Self.blink)) { context in
            let lit = activeState == .key
                && Int(context.date.timeIntervalSince(echo.changedAt) / Self.blink) % 2 == 0
            Color.clear
                .frame(width: 0, height: Self.caretHeight)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.tickerGreen)
                        .frame(width: 2, height: Self.caretHeight)
                        .opacity(lit ? 1 : 0)
                }
        }
    }

    /// How far the text slides left so the caret end of the selection stays inside the line.
    private func sidewaysScroll(before: String) -> CGFloat {
        guard width > 0 else { return 0 }
        let caretX = (before as NSString).size(withAttributes: [.font: Self.measureFont]).width
        return max(0, caretX - (width - 4))
    }
}

private struct InputWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The console's keyboard: an invisible `NSTextField` subclass rather than a SwiftUI `TextField`,
/// since Tab, the arrows, Esc and Ctrl+C / Ctrl+L have to be intercepted and only AppKit sees them.
/// What it holds is mirrored into `ConsoleInputEcho` for the drawn line.
struct ConsoleInputField: NSViewRepresentable {
    @ObservedObject var console: CommandLineConsole
    let echo: ConsoleInputEcho

    func makeNSView(context: Context) -> ConsoleTextField {
        let field = ConsoleTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        field.textColor = .clear
        field.caretColor = .clear
        field.stringValue = console.inputText
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // The field itself decides whether Ctrl+C is a copy (see `ConsoleTextField`).
        // Keys are ignored while "boot" types (Windows collapses the input row then)
        field.onInterrupt = { [weak console] in
            guard let console = console, console.bootScreen == nil else { return }
            console.interrupt()
        }
        field.onClearScreen = { [weak console] in
            guard let console = console, console.bootScreen == nil else { return }
            console.clearScreen()
        }
        context.coordinator.watchSelection(of: field)
        // The console owns the keyboard as soon as it appears.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            context.coordinator.sync(field)
        }
        return field
    }

    func updateNSView(_ field: ConsoleTextField, context: Context) {
        // The console changed the line itself (history, completion, clear).
        if context.coordinator.inputTick != console.inputTick {
            context.coordinator.inputTick = console.inputTick
            field.stringValue = console.inputText
            moveCaretToEnd(in: field)
            // Not during the view update: the echo publishes.
            DispatchQueue.main.async {
                context.coordinator.sync(field)
            }
        }

        // The input line is hidden while "boot" types: take the keyboard away so nothing lands in it (the console
        // calls focusInput() when the boot ends)
        if console.bootScreen != nil, field.currentEditor() != nil {
            DispatchQueue.main.async {
                if let editor = field.currentEditor(), field.window?.firstResponder === editor {
                    field.window?.makeFirstResponder(nil)
                }
            }
        }

        if context.coordinator.focusTick != console.focusTick {
            context.coordinator.focusTick = console.focusTick
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                moveCaretToEnd(in: field)
                context.coordinator.sync(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(console: console, echo: echo)
    }

    private func moveCaretToEnd(in field: NSTextField) {
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let console: CommandLineConsole
        private let echo: ConsoleInputEcho
        private var selectionObserver: NSObjectProtocol?
        var inputTick = 0
        var focusTick = 0

        init(console: CommandLineConsole, echo: ConsoleInputEcho) {
            self.console = console
            self.echo = echo
            self.inputTick = console.inputTick
            self.focusTick = console.focusTick
        }

        deinit {
            if let selectionObserver = selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }

        /// Caret moves and selections change nothing the delegate hears about; the field editor
        /// (shared by the window, so filtered to this field) posts them.
        func watchSelection(of field: NSTextField) {
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification, object: nil, queue: nil
            ) { [weak self, weak field] notification in
                guard let self = self, let field = field,
                      let editor = notification.object as? NSTextView,
                      (editor.delegate as AnyObject?) === field else { return }
                // It can post from inside a view update (a caret moved by `updateNSView`).
                DispatchQueue.main.async {
                    self.sync(field)
                }
            }
        }

        /// Mirrors the field's text and selection into the echo.
        func sync(_ field: NSTextField) {
            let editor = field.currentEditor()
            let text = editor?.string ?? field.stringValue
            let selection = editor?.selectedRange
                ?? NSRange(location: (text as NSString).length, length: 0)
            echo.update(text: text, selection: selection)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, console.bootScreen == nil else { return }
            console.userTyped(field.stringValue)
            sync(field)
        }

        /// Enter runs the line, Tab completes, Up/Down walk the history and Esc clears the line.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if console.bootScreen != nil {
                return true
            }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                console.userTyped(textView.string)
                console.submit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                console.userTyped(textView.string)
                console.completeInput()
                return true
            case #selector(NSResponder.moveUp(_:)):
                console.recallHistory(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                console.recallHistory(1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                console.clearLine()
                return true
            default:
                return false
            }
        }
    }
}

/// The input field: an invisible caret, and Ctrl+C / Ctrl+L taken before the field editor sees them
/// (neither is a standard key binding, so `doCommandBy` never hears about them).
final class ConsoleTextField: NSTextField {
    /// Ctrl+C with nothing selected. With a selection it stays a normal copy.
    var onInterrupt: (() -> Void)?
    /// Ctrl+L.
    var onClearScreen: (() -> Void)?

    /// NSTextField has no `insertionPointColor`; the field editor does, and it is only there once
    /// the field is first responder.
    var caretColor: NSColor?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let editor = currentEditor() as? NSTextView, let caretColor = caretColor {
            editor.insertionPointColor = caretColor
        }
        return became
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .control, let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "c" {
                // Ctrl+C copies when something is selected, and interrupts when nothing is.
                if let editor = currentEditor(), editor.selectedRange.length > 0 {
                    // Ctrl+C isn't a copy key equivalent on macOS, so super did nothing (Windows copies)
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
                    return true
                }
                onInterrupt?()
                return true
            }
            if key == "l" {
                onClearScreen?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - The Elite confirmation

/// "Are you Elite enough?" (spec §6) before entering command line mode from the home screen — the
/// COMMAND tile or View > Command Line Mode. **C** at the boot prompt skips it: that is already a
/// deliberate choice.
struct CommandLineConfirmView: View {
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Are you Elite enough for command line mode?")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.amberAccent)
                .multilineTextAlignment(.center)

            Text("Type \"help\" once you're in. \"gui\" gets you back.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 18)

            HStack(spacing: 10) {
                RetroButton("YES, I'M ELITE", style: .amber) {
                    dismiss()
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)

                RetroButton("NOT TODAY", style: .green) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(EdgeInsets(top: 24, leading: 28, bottom: 20, trailing: 28))
        .background(Color.surface)
        .onExitCommand { dismiss() }
    }
}
