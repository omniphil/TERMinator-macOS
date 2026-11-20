import AppKit
import Foundation
import SwiftUI

/// When the app started, for the console's `uptime`. Windows reads the process start time from the
/// OS; macOS has no cheap Swift equivalent (the `kinfo_proc` union isn't importable), so
/// `TERMinatorApp.init` stamps this at launch instead.
enum AppLaunch {
    private(set) static var startedAt = Date()

    static func markStart() {
        startedAt = Date()
    }
}

/// The `TERMinator>` command line (spec §6): a small interpreter over the phonebook, connecting, a
/// few network tools and some fun. `CommandLineView` draws it. Mirrors the Windows client's
/// `Controls/CommandLineOverlay.cs`.
///
/// **One instance for the app's lifetime** (`shared`), so scrollback and history survive every
/// visit — the host only shows and hides it.
///
/// Windows' `ICommandLineHost` is the `onConnect` / `onMatrix` closures here: the host (ContentView)
/// is a struct and can't implement a protocol for it. Everything else the console reaches itself
/// through the app's singletons (`BBSEntryStore`, `CrtSettingsStore`, `UserDefaults`).
///
/// The command table holds metadata only; `run(_:args:)` switches on the name. That keeps ~35
/// command closures (and their retain cycles) out of the object.
///
/// Called from the main thread only, like the app's other stores (`AppState`, `BBSEntryStore`): the
/// class isn't `@MainActor` — that would force every SwiftUI and AppKit caller to be isolated too —
/// but every long command's task body is, so `@Published` is never touched off the main thread.
final class CommandLineConsole: ObservableObject {
    static let shared = CommandLineConsole()

    // MARK: - Output

    /// Output line color (spec §6): normal `#55DD55`, success `#33FF33`, dim `#888899`,
    /// accent `#FFAA00`, error `#FF5555` — all already in the theme.
    enum Style {
        case normal, success, dim, accent, error

        var color: Color {
            switch self {
            case .normal: return .tickerGreen        // #55DD55
            case .success: return .accentGreen       // #33FF33
            case .dim: return .textSecondary         // #888899
            case .accent: return .amberAccent        // #FFAA00
            case .error: return .termLightRed        // #FF5555
            }
        }
    }

    /// One output line. A prompt line draws `TERMinator> ` in the logo's colors followed by the
    /// echoed command in `text`.
    struct Line: Identifiable {
        let id: Int
        let text: String
        let style: Style
        let isPrompt: Bool
    }

    private static let maxOutputLines = 1000
    private static let probeTimeout: TimeInterval = 3
    private static let wardialGap: UInt64 = 400_000_000

    @Published private(set) var lines: [Line] = []
    /// Bumped by every write, so the view scrolls to the bottom (the line count alone stops
    /// changing once the scrollback is full).
    @Published private(set) var scrollTick = 0
    @Published private(set) var isVisible = false
    /// The `boot` command's screen while it types; the input line is hidden until it's done.
    @Published private(set) var bootScreen: String?
    /// Bumped when the console wants the keyboard back in the input line.
    @Published private(set) var focusTick = 0
    /// Bumped when the console itself changed the input line (history, completion, clear).
    @Published private(set) var inputTick = 0

    /// The text on the input line. Deliberately **not** `@Published`: the AppKit field owns the
    /// text while the user types, so a keystroke doesn't re-render a thousand output lines.
    private(set) var inputText = ""

    private var nextLineId = 0

    // MARK: - Host actions

    /// Leaves the console and connects (the host brings the console back when the session ends).
    var onConnect: ((BBSEntry) -> Void)?
    /// Plays the digital rain over the console; the host gives the console focus back after.
    var onMatrix: (() -> Void)?

    // MARK: - State

    private var history: [String] = []
    private var historyPosition = 0

    /// A running long command (ping, wardial, resolve, hack); Ctrl+C cancels it.
    private var busyTask: Task<Void, Never>?
    /// The `boot` replay, which hides the input line instead of marking the console busy.
    private var bootTask: Task<Void, Never>?
    /// Set while a y/n question is waiting; the next line answers it.
    private var pendingConfirm: ((Bool) -> Void)?

    /// The last board called from here (connect / dial / redial), for `redial`.
    private var lastCalled: BBSEntry?
    /// The last unsaved `dial` target, for `save`.
    private var lastDialed: BBSEntry?

    private init() {
        writeWelcome()
    }

    private func writeWelcome() {
        write("TERMinator command line v\(AppInfo.version)", .accent)
        write("Type \"help\" for commands. Tab completes commands and board names.", .dim)
        write(" ", .normal)
    }

    // MARK: - Show / hide

    /// Shows the console, optionally with a highlighted status line (a session's return notice).
    /// `boot` types the boot sequence into it first, then the welcome, for entering from the home
    /// screen; a second request while it's still typing is ignored.
    func show(notice: String?, boot: Bool = false) {
        isVisible = true
        if let notice = notice {
            write(notice, .accent)
        }
        if boot {
            if bootTask == nil {
                typeBootSequence(thenWelcome: true)
            }
        } else {
            focusInput()
        }
    }

    func hide() {
        isVisible = false
    }

    func focusInput() {
        focusTick += 1
    }

    // MARK: - Input line

    /// The field reports what the user typed.
    func userTyped(_ text: String) {
        inputText = text
    }

    /// Enter: echo the prompt and the line, then run it.
    func submit() {
        let line = inputText
        setInput("")
        execute(line)
    }

    /// Esc: clear the line.
    func clearLine() {
        setInput("")
    }

    /// Ctrl+L: clear the screen.
    func clearScreen() {
        lines.removeAll()
        scrollTick += 1
    }

    /// Ctrl+C with nothing selected: cancel a running command, else echo `<line>^C`, clear the
    /// line and drop any pending y/n question.
    func interrupt() {
        if let task = busyTask {
            task.cancel()
            return
        }
        echo(inputText + "^C")
        setInput("")
        pendingConfirm = nil
    }

    /// Up / Down: walk the history (-1 back, +1 forward).
    func recallHistory(_ step: Int) {
        guard !history.isEmpty else { return }
        historyPosition = min(max(historyPosition + step, 0), history.count)
        setInput(historyPosition < history.count ? history[historyPosition] : "")
    }

    private func setInput(_ text: String) {
        inputText = text
        inputTick += 1
    }

    // MARK: - Interpreter

    private func execute(_ line: String) {
        echo(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // A y/n question is waiting: this line is the answer, and isn't added to the history.
        if let confirm = pendingConfirm {
            pendingConfirm = nil
            let answer = trimmed.lowercased()
            confirm(answer == "y" || answer == "yes")
            return
        }

        guard !trimmed.isEmpty else { return }

        // The line goes into the history before anything runs, so a line refused with "busy." is
        // still there. Consecutive duplicates aren't re-added.
        if history.last != trimmed {
            history.append(trimmed)
        }
        historyPosition = history.count

        if busyTask != nil {
            write("busy. Press Ctrl+C to cancel.", .dim)
            return
        }

        let name: String
        let args: String
        if let space = trimmed.firstIndex(of: " ") {
            name = String(trimmed[trimmed.startIndex..<space])
            args = String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        } else {
            name = trimmed
            args = ""
        }

        guard let command = findCommand(name) else {
            write("'\(name)' is not a command. Type \"help\" for the list.", .error)
            return
        }
        run(command, args: args)
    }

    /// Runs a long command (network, animations) without blocking the console; Ctrl+C cancels it.
    private func runAsync(_ work: @escaping @MainActor () async throws -> Void) {
        guard busyTask == nil else { return }
        busyTask = Task { @MainActor [weak self] in
            do {
                try await work()
            } catch is CancellationError {
                self?.write("^C  cancelled", .dim)
            } catch {
                self?.write("error: \(error.localizedDescription)", .error)
            }
            self?.busyTask = nil
        }
    }

    // MARK: - Command table

    /// What Tab offers after a command name.
    private enum ArgPool {
        case noArgs
        case commands
        case boardNames
        case boardNamesAndHosts
        case dial
        case quickConnect
        case crt
        case phosphor
        case baud
    }

    private struct Command {
        let name: String
        let group: String
        let aliases: [String]
        let usage: String
        let summary: String
        let args: ArgPool
        /// Works, but isn't listed by `help` or offered by Tab.
        let hidden: Bool

        init(_ name: String, _ group: String, _ aliases: [String], _ usage: String, _ summary: String,
             args: ArgPool = .noArgs, hidden: Bool = false) {
            self.name = name
            self.group = group
            self.aliases = aliases
            self.usage = usage
            self.summary = summary
            self.args = args
            self.hidden = hidden
        }
    }

    private static let groups = ["Boards", "Network", "System"]

    /// In `help` order. `quit` stays last, and the two hidden commands stay after it.
    private static let commands: [Command] = [
        // Boards
        Command("list", "Boards", ["ls", "dir", "phonebook"], "list [filter]", "Show the boards in your phonebook"),
        Command("recent", "Boards", [], "recent", "Boards you called most recently"),
        Command("info", "Boards", [], "info <#|name>", "Show a board's connection details", args: .boardNames),
        Command("stats", "Boards", [], "stats [#|name]",
                "Your call log: calls, time online and data, for every board or one", args: .boardNames),
        Command("connect", "Boards", ["call"], "connect <#|name>",
                "Connect to a phonebook board by number or name", args: .boardNames),
        Command("redial", "Boards", [], "redial", "Call the last board again"),
        Command("dial", "Boards", [], "dial <host[:port]> [telnet|ssh|telnets|ws|wss|raw]",
                "Connect to any address without adding it to the phonebook (ssh: user@host)", args: .dial),
        Command("add", "Boards", [], "add <name> <host[:port]> [telnet|ssh|telnets|ws|wss|raw]",
                "Add a board to the phonebook (names may contain spaces)"),
        Command("save", "Boards", [], "save [name]", "Save the last board you dialed to the phonebook"),
        Command("remove", "Boards", ["rm", "del"], "remove <#|name>",
                "Remove a board from the phonebook (asks first)", args: .boardNames),
        Command("qc", "Boards", [], "qc [<1-4> <#|name>|clear]",
                "Show the Quick Connect slots, or set / clear one", args: .quickConnect),
        Command("export", "Boards", [], "export", "Export the phonebook to a file"),
        Command("import", "Boards", [], "import", "Import a phonebook from a file"),

        // Network
        Command("resolve", "Network", ["nslookup"], "resolve <host|#|name>",
                "Look up a host's addresses (doesn't contact the board)", args: .boardNamesAndHosts),
        Command("ping", "Network", [], "ping <#|name|host[:port]>",
                "See whether a board answers, and how fast (makes one real call)", args: .boardNamesAndHosts),
        Command("wardial", "Network", [], "wardial", "Ping every board in your phonebook to see if the board is up"),

        // System
        Command("crt", "System", [], "crt [on|off]", "Show or switch CRT mode", args: .crt),
        Command("baud", "System", ["speed"], "baud [off|300|1200|2400|9600|14.4k|19.2k|28.8k|33.6k|56k]",
                "Show or set the emulated modem speed", args: .baud),
        Command("phosphor", "System", [], "phosphor [color|green|amber|white]",
                "Show or switch the monochrome tube color", args: .phosphor),
        Command("whoami", "System", [], "whoami", "Your operator profile"),
        Command("rank", "System", ["elite"], "rank", "Your elite status and how far to the next rank"),
        Command("date", "System", [], "date", "The current date and time"),
        Command("uptime", "System", [], "uptime", "How long TERMinator has been running"),
        Command("motd", "System", [], "motd", "Message of the day"),
        Command("ver", "System", ["version"], "ver", "Show the TERMinator version"),
        Command("about", "System", [], "about", "About TERMinator and the people behind it"),
        Command("changelog", "System", [], "changelog", "What's new in each version"),
        Command("clear", "System", ["cls"], "clear", "Clear the screen"),
        Command("help", "System", ["?"], "help [command]", "List the commands, or show how to use one",
                args: .commands),
        Command("gui", "System", ["exit"], "gui", "Load the graphical TERMinator home screen"),
        Command("fact", "System", [], "fact", "A random piece of computing and BBS history"),
        Command("hack", "System", [], "hack <#|name>", "Totally real hacking. Definitely.", args: .boardNames),
        Command("boot", "System", [], "boot", "Clear the screen and replay the boot sequence"),
        Command("quit", "System", [], "quit", "Close TERMinator"),

        // Secret: they work, but aren't listed by "help" or offered by Tab
        Command("matrix", "System", [], "matrix", "Enter the digital rain", hidden: true),
        Command("sudo", "System", [], "sudo <anything>", "Try it", hidden: true),
    ]

    private func findCommand(_ name: String) -> Command? {
        let wanted = name.lowercased()
        return Self.commands.first { command in
            command.name.lowercased() == wanted || command.aliases.contains { $0.lowercased() == wanted }
        }
    }

    private func run(_ command: Command, args: String) {
        switch command.name {
        case "list": list(filter: args)
        case "recent": recent()
        case "info": info(args)
        case "stats": stats(args)
        case "connect": connect(args)
        case "redial": redial()
        case "dial": dial(args)
        case "add": addBoard(args)
        case "save": save(args)
        case "remove": remove(args)
        case "qc": quickConnect(args)
        case "export": exportPhonebook()
        case "import": importPhonebook()
        case "resolve": resolve(args)
        case "ping": ping(args)
        case "wardial": wardial()
        case "crt": crt(args)
        case "baud": baud(args)
        case "phosphor": phosphor(args)
        case "whoami": whoAmI()
        case "rank": rank()
        case "date": write(Self.stamp(Date(), format: "EEE MMM dd HH:mm:ss yyyy"), .normal)
        case "uptime": uptime()
        case "motd": motd()
        case "ver": write("TERMinator v\(AppInfo.version)", .accent)
        case "about": about()
        case "changelog": changelog()
        case "clear": clearScreen()
        case "help": help(args)
        case "gui": hide()
        case "fact": fact()
        case "hack": hack(args)
        case "boot": typeBootSequence()
        case "quit":
            // The app delegate intercepts this and plays the CRT power-off before it really quits
            // (spec §7).
            NSApp.terminate(nil)
        case "matrix": onMatrix?()
        case "sudo": write("nice try.", .error)
        default: break
        }
    }

    // MARK: - Boards

    private var boards: [BBSEntry] {
        BBSEntryStore.shared.entries
    }

    private func help(_ args: String) {
        if !args.isEmpty {
            guard let command = findCommand(args) else {
                write("No such command: \(args)", .error)
                return
            }
            write("  \(command.usage)", .accent)
            write("  \(command.summary)", .normal)
            if !command.aliases.isEmpty {
                write("  also: \(command.aliases.joined(separator: ", "))", .dim)
            }
            return
        }

        for group in Self.groups {
            write(group, .accent)
            for command in Self.commands where command.group == group && !command.hidden {
                write("  \(Self.padRight(command.name, 9)) \(command.summary)", .normal)
            }
        }
        write(" ", .normal)
        write("\"help <command>\" shows how to use one.", .dim)
        write("Tab: complete   Up/Down: history   Esc: clear the line   Ctrl+C: clear / cancel   Ctrl+L: clear the screen",
              .dim)
    }

    private func list(filter: String) {
        let boards = self.boards
        guard !boards.isEmpty else {
            write("The phonebook is empty. Try \"add\" or \"dial\".", .dim)
            return
        }

        write("  \(Self.padLeft("#", 3))  \(Self.padRight("NAME", 28)) \(Self.padRight("PROTO", 8)) ADDRESS", .accent)
        var shown = 0
        for (index, board) in boards.enumerated() {
            if !filter.isEmpty
                && board.name.range(of: filter, options: .caseInsensitive) == nil
                && board.host.range(of: filter, options: .caseInsensitive) == nil {
                continue
            }
            write("  \(Self.padLeft("\(index + 1)", 3))  \(Self.padRight(Self.truncate(board.name, 28), 28))"
                  + " \(Self.padRight(board.connectionProtocol.tracerName, 8)) \(board.host):\(board.port)", .normal)
            shown += 1
        }
        if shown == 0 {
            write("No boards match \"\(filter)\".", .dim)
        }
    }

    private func recent() {
        let called = Array(recentlyCalled().prefix(10))
        guard !called.isEmpty else {
            write("No calls yet.", .dim)
            return
        }
        for board in called {
            let when = board.lastConnected.map { Self.stamp($0, format: "yyyy-MM-dd HH:mm") } ?? ""
            write("  \(when)  \(Self.padRight(Self.truncate(board.name, 28), 28)) \(board.host):\(board.port)", .normal)
        }
    }

    private func info(_ args: String) {
        guard let board = resolveBoard(args) else { return }
        write("  \(board.name)", .accent)
        write("  address   : \(board.host):\(board.port)", .normal)
        write("  protocol  : \(board.connectionProtocol.tracerName)", .normal)
        if !board.username.isEmpty {
            write("  username  : \(board.username)", .normal)
        }
        let last = board.lastConnected.map { Self.stamp($0, format: "yyyy-MM-dd HH:mm") } ?? "never"
        write("  last call : \(last)", .normal)
    }

    /// "stats": the call log for every board (busiest first), or one board in detail.
    private func stats(_ args: String) {
        let duration = CallStatsService.formatDuration
        let size = CallStatsService.formatBytes
        let log = CallStatsService.shared
        let minute = CallStatsService.minuteFormatter

        if !args.isEmpty {
            guard let board = resolveBoard(args) else { return }
            write("  \(board.name)", .accent)
            guard let stats = log.get(board.id.uuidString), stats.calls > 0 else {
                write("  No calls logged yet.", .dim)
                return
            }
            write("  calls      : \(stats.calls)", .normal)
            write("  first call : \(minute.string(from: stats.firstCall))", .normal)
            write("  last call  : \(minute.string(from: stats.lastCall))", .normal)
            write("  online     : \(duration(stats.secondsOnline))  (about \(duration(stats.secondsOnline / Double(stats.calls))) a call)",
                  .normal)
            write("  received   : \(size(stats.bytesReceived))", .normal)
            write("  sent       : \(size(stats.bytesSent))", .normal)
            return
        }

        let all = log.all.filter { $0.calls > 0 }
        guard !all.isEmpty else {
            write("No calls logged yet.", .dim)
            return
        }

        let calls = all.reduce(0) { $0 + $1.calls }
        let online = all.reduce(0.0) { $0 + $1.secondsOnline }
        let received = all.reduce(Int64(0)) { $0 + $1.bytesReceived }
        let sent = all.reduce(Int64(0)) { $0 + $1.bytesSent }
        write("CALL LOG", .accent)
        write("  \(calls) calls to \(all.count) board\(all.count == 1 ? "" : "s"), \(duration(online)) online, "
              + "\(size(received)) received, \(size(sent)) sent", .normal)
        write(" ", .normal)
        write("  \(Self.padRight("BOARD", 28)) \(Self.padLeft("CALLS", 5))  \(Self.padRight("ONLINE", 9))  LAST CALL", .accent)
        for stats in all.sorted(by: { $0.secondsOnline > $1.secondsOnline }).prefix(10) {
            write("  \(Self.padRight(Self.truncate(stats.name, 28), 28)) \(Self.padLeft("\(stats.calls)", 5))  "
                  + "\(Self.padRight(duration(stats.secondsOnline), 9))  \(minute.string(from: stats.lastCall))", .normal)
        }
        if all.count > 10 {
            write("  ... and \(all.count - 10) more", .dim)
        }
        write("\"stats <#|name>\" shows one board.", .dim)
    }

    private func connect(_ args: String) {
        guard let board = resolveBoard(args) else { return }
        call(board, label: board.name)
    }

    private func redial() {
        guard let target = lastCalled ?? recentlyCalled().first else {
            write("Nothing to redial yet.", .error)
            return
        }
        call(target, label: target.name)
    }

    private func dial(_ args: String) {
        let parts = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 1 || parts.count == 2 else {
            write("usage: dial <host[:port]> [telnet|ssh|telnets|ws|wss|raw]", .error)
            return
        }

        var proto = ConnectionProtocol.telnet
        if parts.count == 2 {
            guard let parsed = Self.parseProtocol(parts[1]) else {
                write("Unknown protocol \"\(parts[1])\". Use telnet, ssh, telnets, ws, wss or raw.", .error)
                return
            }
            proto = parsed
        }

        guard let target = Self.parseTarget(parts[0], protocol: proto) else {
            write("\"\(parts[0])\" isn't a valid host[:port].", .error)
            return
        }

        let connection = makeConnection(host: target.host, port: target.port,
                                        protocol: proto, username: target.username)
        lastDialed = connection
        call(connection, label: "dial")
    }

    private func call(_ connection: BBSEntry, label: String) {
        lastCalled = connection
        write("ATDT \(connection.host):\(connection.port)  (\(label), \(connection.connectionProtocol.tracerName))",
              .accent)
        onConnect?(connection)
    }

    private func addBoard(_ args: String) {
        var tokens = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var proto = ConnectionProtocol.telnet
        if tokens.count >= 3, let parsed = Self.parseProtocol(tokens[tokens.count - 1]) {
            proto = parsed
            tokens.removeLast()
        }
        guard tokens.count >= 2 else {
            write("usage: add <name> <host[:port]> [telnet|ssh|telnets|ws|wss|raw]", .error)
            return
        }

        let address = tokens.removeLast()
        let name = tokens.joined(separator: " ")

        guard let target = Self.parseTarget(address, protocol: proto) else {
            write("\"\(address)\" isn't a valid host[:port].", .error)
            return
        }
        if let existing = findByAddress(host: target.host, port: target.port) {
            write("\(target.host):\(target.port) is already in the phonebook as \"\(existing.name)\".", .error)
            return
        }

        var board = makeConnection(host: target.host, port: target.port,
                                   protocol: proto, username: target.username)
        board.name = name
        BBSEntryStore.shared.addEntry(board)
        write("Added \"\(name)\" as #\(boards.count).", .success)
    }

    private func save(_ args: String) {
        guard var dialed = lastDialed else {
            write("Nothing to save. \"dial\" a board first.", .error)
            return
        }
        if let existing = findByAddress(host: dialed.host, port: dialed.port) {
            write("\(dialed.host):\(dialed.port) is already in the phonebook as \"\(existing.name)\".", .error)
            return
        }

        if !args.isEmpty {
            dialed.name = args
        }
        BBSEntryStore.shared.addEntry(dialed)
        write("Saved \"\(dialed.name)\" as #\(boards.count).", .success)
        lastDialed = nil
    }

    private func remove(_ args: String) {
        guard let board = resolveBoard(args) else { return }

        write("Remove \"\(board.name)\" (\(board.host):\(board.port)) from the phonebook? (y/n)", .accent)
        pendingConfirm = { [weak self] yes in
            guard let self = self else { return }
            if yes {
                // The Quick Connect tiles resolve their board from the store by id, so a removed
                // board leaves its tile empty on its own (Windows has to refresh them by hand).
                BBSEntryStore.shared.deleteEntry(board)
                self.write("Removed \"\(board.name)\".", .success)
            } else {
                self.write("Kept it.", .dim)
            }
        }
    }

    private func quickConnect(_ args: String) {
        let parts = Self.splitFirst(args)
        guard let first = parts.head else {
            for slot in 1...4 {
                if let board = Self.quickConnectBoard(slot: slot) {
                    write("  \(slot): \(board.name)  \(board.host):\(board.port)", .normal)
                } else {
                    write("  \(slot): (empty)", .dim)
                }
            }
            return
        }

        guard let number = Int(first), (1...4).contains(number), let rest = parts.tail, !rest.isEmpty else {
            write("usage: qc [<1-4> <#|name>|clear]", .error)
            return
        }

        if rest.lowercased() == "clear" {
            UserDefaults.standard.set("", forKey: AppPreferences.quickConnectKey(number))
            write("Quick Connect \(number) cleared.", .success)
            return
        }

        guard let target = resolveBoard(rest) else { return }
        UserDefaults.standard.set(target.id.uuidString, forKey: AppPreferences.quickConnectKey(number))
        write("Quick Connect \(number) is now \"\(target.name)\".", .success)
    }

    /// The same flows as File > Export / Import Phonebook (`ImportExportManager.runExportFlow` /
    /// `runImportFlow`), as Windows' console calls the host's menu handlers: the save/open panel, the
    /// merge-or-replace question and the result all come up as dialogs, then focus returns here.
    private func exportPhonebook() {
        ImportExportManager.shared.runExportFlow { [weak self] _ in
            DispatchQueue.main.async { self?.focusInput() }
        }
    }

    private func importPhonebook() {
        ImportExportManager.shared.runImportFlow { [weak self] _ in
            DispatchQueue.main.async { self?.focusInput() }
        }
    }

    // MARK: - Network

    private func resolve(_ args: String) {
        var host: String?
        if !args.isEmpty {
            host = resolveBoard(args, report: false)?.host ?? Self.splitHostPort(args)?.host
        }
        guard let target = host else {
            write("usage: resolve <host|#|name>", .error)
            return
        }

        runAsync { [weak self] in
            let clock = Date()
            let addresses = try await ConsoleNetwork.addresses(of: target)
            guard let self = self else { return }
            self.write("\(target)  (\(Self.milliseconds(since: clock)) ms)", .accent)
            for address in addresses {
                self.write("  \(address.isIPv6 ? "IPv6" : "IPv4")  \(address.text)", .normal)
            }
            if addresses.isEmpty {
                self.write("  no addresses", .dim)
            }
        }
    }

    private func ping(_ args: String) {
        // A board, or a bare address (port 23 when it has none).
        let target: (host: String, port: Int, label: String)
        if let board = resolveBoard(args, report: false) {
            target = (host: board.host, port: board.port, label: board.name)
        } else if !args.isEmpty, let parsed = Self.splitHostPort(args) {
            target = (host: parsed.host, port: parsed.port ?? 23, label: parsed.host)
        } else {
            write("usage: ping <#|name|host[:port]>", .error)
            return
        }
        let host = target.host
        let port = target.port
        let label = target.label

        runAsync { [weak self] in
            self?.write("ATDT \(host):\(port) ...", .dim)
            let result = try await ConsoleNetwork.probe(host: host, port: port, timeout: Self.probeTimeout)
            guard let self = self else { return }
            if result.answered {
                self.write("CARRIER \(host):\(port)  time=\(result.milliseconds)ms  (\(label))", .success)
            } else {
                self.write("NO CARRIER \(host):\(port)  (\(result.error ?? "no answer"))", .error)
            }
        }
    }

    private func wardial() {
        let boards = self.boards
        guard !boards.isEmpty else {
            write("The phonebook is empty. Nothing to dial.", .dim)
            return
        }

        runAsync { [weak self] in
            self?.write("war dialing \(boards.count) boards (Ctrl+C to stop)...", .accent)
            var answered = 0
            for (index, board) in boards.enumerated() {
                try Task.checkCancellation()
                let result = try await ConsoleNetwork.probe(host: board.host, port: board.port,
                                                           timeout: Self.probeTimeout)
                guard let self = self else { return }
                if result.answered {
                    answered += 1
                }
                let outcome = result.answered
                    ? "CARRIER     \(Self.padLeft("\(result.milliseconds)", 5))ms"
                    : "NO CARRIER         "
                let detail = result.answered ? "" : "  (\(result.error ?? "no answer"))"
                self.write("  \(Self.padLeft("\(index + 1)", 3))  \(outcome)"
                           + "  \(Self.padRight(Self.truncate(board.name, 28), 28)) \(board.host):\(board.port)\(detail)",
                           result.answered ? .success : .error)

                // Go easy on the boards: a short gap between calls
                if index < boards.count - 1 {
                    try await Task.sleep(nanoseconds: Self.wardialGap)
                }
            }
            self?.write("\(answered)/\(boards.count) boards answered.", .accent)
        }
    }

    // MARK: - System

    /// "baud": shows or sets the emulated modem speed. Writes the same setting as Call > Modem Speed; ContentView
    /// hands it to the native bridge.
    private func baud(_ args: String) {
        let text = args.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            let current = UserDefaults.standard.integer(forKey: AppPreferences.emulatedBaud)
            write(current > 0 ? "Emulated speed is \(ModemSpeeds.label(current))." : "Speed emulation is OFF (full speed).",
                  .normal)
            return
        }

        guard let bps = ModemSpeeds.parse(text) else {
            write("usage: baud [\(ModemSpeeds.shortNames.joined(separator: "|"))]", .error)
            return
        }

        UserDefaults.standard.set(bps, forKey: AppPreferences.emulatedBaud)
        NativeBridge.shared.setEmulatedBps(bps)
        write(bps > 0 ? "Emulated speed set to \(ModemSpeeds.label(bps))." : "Speed emulation OFF.", .success)
    }

    private func crt(_ args: String) {
        switch args.lowercased() {
        case "":
            write("CRT mode is \(CrtSettingsStore.shared.current.enabled ? "ON" : "OFF").", .normal)
        case "on":
            setCrtEnabled(true)
            write("CRT mode ON.", .success)
        case "off":
            setCrtEnabled(false)
            write("CRT mode OFF.", .success)
        default:
            write("usage: crt [on|off]", .error)
        }
    }

    /// The store publishes and saves, so the terminal, the thumbnails, the CRT window and the
    /// console's own screen effect all follow.
    private func setCrtEnabled(_ enabled: Bool) {
        var settings = CrtSettingsStore.shared.current
        guard settings.enabled != enabled else { return }
        settings.enabled = enabled
        CrtSettingsStore.shared.current = settings
    }

    private func phosphor(_ args: String) {
        let mode: String?
        switch args.lowercased() {
        case "": mode = nil
        case "color": mode = PhosphorMode.color.rawValue
        case "green": mode = PhosphorMode.green.rawValue
        case "amber": mode = PhosphorMode.amber.rawValue
        case "white": mode = PhosphorMode.white.rawValue
        default:
            write("usage: phosphor [color|green|amber|white]", .error)
            return
        }

        guard let mode = mode else {
            write("Phosphor is \(Self.currentPhosphor).", .normal)
            return
        }
        // The View > Phosphor check and the tint on the home screen / console read this key.
        UserDefaults.standard.set(mode, forKey: AppPreferences.phosphor)
        write("Phosphor \(mode).", .success)
    }

    private static var currentPhosphor: String {
        UserDefaults.standard.string(forKey: AppPreferences.phosphor) ?? PhosphorMode.color.rawValue
    }

    private func rank() {
        let barWidth = 20
        let calls = EliteRank.totalCalls
        let current = EliteRank.name(for: calls)
        let currentMin = EliteRank.all.last { calls >= $0.minCalls }?.minCalls ?? 0

        write("ELITE STATUS", .accent)
        write("  rank  : \(current)  (\(calls) call\(calls == 1 ? "" : "s"))", .normal)
        if let next = EliteRank.next(for: calls) {
            let span = max(1, next.calls - currentMin)
            let fraction = Double(calls - currentMin) / Double(span)
            // Windows rounds with `Math.Round`'s default (banker's/to-even) rule; Swift's default
            // `.rounded()` rounds half away from zero, which would fill the bar one tick too far
            // exactly at the .5 boundary.
            let filled = min(barWidth, max(0, Int((fraction * Double(barWidth)).rounded(.toNearestOrEven))))
            let bar = String(repeating: "#", count: filled) + String(repeating: "-", count: barWidth - filled)
            write("  next  : \(next.name) at \(next.calls) calls  [\(bar)]  \(next.calls - calls) to go", .normal)
        } else {
            write("  next  : none. You're a \(current). Respect.", .success)
        }
        write("", .normal)

        for rank in EliteRank.all {
            let row = "  \(Self.padRight(rank.name, 8))\(Self.padLeft("\(rank.minCalls)", 4))+ calls"
            if rank.name == current {
                write("\(row)   <- you", .accent)
            } else {
                write(row, rank.minCalls < currentMin ? .success : .dim)
            }
        }
        write("", .normal)
        write("Every successful BBS connection counts.", .dim)
    }

    private func whoAmI() {
        let last = recentlyCalled().first
        let calls = EliteRank.totalCalls
        let progress = EliteRank.next(for: calls).map { ", \($0.calls - calls) more to \($0.name)" } ?? ""
        write("  handle    : \(NSUserName())", .normal)
        write("  rank      : \(EliteRank.name(for: calls))  (\(calls) call\(calls == 1 ? "" : "s")\(progress))", .normal)
        write("  boards    : \(boards.count) in phonebook", .normal)
        if let last = last, let when = last.lastConnected {
            write("  last call : \(last.name) (\(Self.stamp(when, format: "yyyy-MM-dd HH:mm")))", .normal)
        } else {
            write("  last call : never", .normal)
        }
        write("  client    : TERMinator v\(AppInfo.version)", .normal)
    }

    private func uptime() {
        let up = Int(max(0, Date().timeIntervalSince(AppLaunch.startedAt)))
        let hours = up / 3600
        let minutes = (up % 3600) / 60
        let seconds = up % 60
        write("\(Self.stamp(Date(), format: "HH:mm:ss")) up \(hours):\(Self.pad2(minutes)):\(Self.pad2(seconds)), "
              + "\(boards.count) boards, CRT \(CrtSettingsStore.shared.current.enabled ? "ON" : "OFF")", .normal)
    }

    private func motd() {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case ..<5: greeting = "Burning the midnight oil"
        case ..<12: greeting = "Good morning"
        case ..<18: greeting = "Good afternoon"
        default: greeting = "Good evening"
        }
        write("\(greeting), \(NSUserName()). Welcome to TERMinator v\(AppInfo.version).", .accent)

        let facts = HistoryFacts.all
        if !facts.isEmpty {
            // ⚠️ `DateComponents.dayOfYear` is macOS 15; ordinality is the portable way.
            let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
            write("Fact of the day: " + facts[dayOfYear % facts.count], .normal)
        }
    }

    private func about() {
        write("TERMinator - BBS Terminal", .accent)
        write("Version \(AppInfo.version)", .normal)
        write("", .normal)
        write("\u{2500}\u{2500}\u{2500} Credits \u{2500}\u{2500}\u{2500}", .accent)
        write("", .normal)
        for line in AppInfo.creditsLines {
            write(line, .normal)
        }
    }

    private func changelog() {
        write("TERMinator - BBS Terminal", .accent)
        write("Version \(AppInfo.version)", .normal)
        write("", .normal)
        write("\u{2500}\u{2500}\u{2500} What's New \u{2500}\u{2500}\u{2500}", .accent)
        write("", .normal)
        for line in AppInfo.changelogLines {
            write(line, line.hasPrefix("v") ? .accent : .normal)
        }
    }

    // MARK: - Fun

    private func fact() {
        if let fact = HistoryFacts.all.randomElement() {
            write(fact, .normal)
        }
    }

    private func hack(_ args: String) {
        // Needs a real phonebook board: a number or a name
        guard !args.isEmpty else {
            write("usage: hack <#|name>", .error)
            return
        }
        guard let board = resolveBoard(args) else { return }

        let steps = [
            "[*] target acquired: \(board.name)",
            "[*] spoofing caller ID ... 555-0199",
            "[*] bypassing firewall  [#####-----]  50%",
            "[*] bypassing firewall  [##########] 100%",
            "[*] injecting ANSI payload ...",
            "[*] cracking sysop password: ********",
            "[!] The SysOp broke into chat: \"I can see you. Want to play a door game instead?\"",
            "[!] ACCESS DENIED. Maybe just call in and say hi.",
        ]

        runAsync { [weak self] in
            for (index, step) in steps.enumerated() {
                try await Task.sleep(nanoseconds: index == 0 ? 150_000_000 : 420_000_000)
                self?.write(step, step.hasPrefix("[!]") ? .error : .normal)
            }
        }
    }

    /// `boot`: clears the screen and types the boot sequence into the console at the boot screen's
    /// own pace, then the prompt returns right under it. Nothing is cleared afterwards, and keys are
    /// ignored while it types (the input line is hidden until it's done). `thenWelcome` follows it
    /// with a blank line and the welcome (entering from the home screen).
    private func typeBootSequence(thenWelcome: Bool = false) {
        bootTask?.cancel()
        let bootLines = BootSequenceView.launchLines()
        let totalUnits = BootSequenceModel.totalUnits(bootLines)

        lines.removeAll()
        bootScreen = ""
        scrollTick += 1

        bootTask = Task { @MainActor [weak self] in
            let started = Date()
            while true {
                let progress = min(1, Date().timeIntervalSince(started) / BootSequenceModel.typingDuration)
                let units = Int((progress * Double(totalUnits)).rounded())
                let shown = BootSequenceModel.buildScreen(bootLines, units: units)
                guard let self = self else { return }
                if progress >= 1 {
                    var finished = shown
                    while finished.hasSuffix("\n") {
                        finished.removeLast()
                    }
                    self.bootScreen = nil
                    for line in finished.components(separatedBy: "\n") {
                        self.write(line, .normal)
                    }
                    if thenWelcome {
                        self.write(" ", .normal)
                        self.writeWelcome()
                    }
                    break
                }
                self.bootScreen = shown + "\u{2588}"
                self.scrollTick += 1
                try? await Task.sleep(nanoseconds: 15_000_000)
                if Task.isCancelled {
                    return
                }
            }
            self?.focusInput()
            self?.bootTask = nil
        }
    }

    // MARK: - Lookups

    /// A board by 1-based number ("3" or "#3"), exact name, or unique partial name. With `report`
    /// it explains why nothing matched.
    private func resolveBoard(_ query: String, report: Bool = true) -> BBSEntry? {
        let boards = self.boards
        guard !query.isEmpty else {
            if report {
                write("Which board? Give a number or a name (see \"list\").", .error)
            }
            return nil
        }

        if let number = Int(String(query.drop(while: { $0 == "#" }))) {
            if number >= 1 && number <= boards.count {
                return boards[number - 1]
            }
            if report {
                write("There is no board #\(number). The phonebook has \(boards.count).", .error)
            }
            return nil
        }

        let exact = boards.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        if exact.count == 1 {
            return exact[0]
        }

        var matches = boards.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
        if matches.isEmpty {
            matches = boards.filter { $0.name.range(of: query, options: .caseInsensitive) != nil }
        }
        if matches.count == 1 {
            return matches[0]
        }

        guard report else { return nil }
        if matches.isEmpty {
            write("No board matches \"\(query)\".", .error)
        } else {
            write("\"\(query)\" matches \(matches.count) boards:", .error)
            for board in matches.prefix(10) {
                write("  \(board.name)", .dim)
            }
        }
        return nil
    }

    private func findByAddress(host: String, port: Int) -> BBSEntry? {
        boards.first { $0.port == port && $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    private func recentlyCalled() -> [BBSEntry] {
        boards.filter { $0.lastConnected != nil }
            .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
    }

    /// An unsaved connection for an ad-hoc `dial`, with the user's default font and screen mode.
    private func makeConnection(host: String, port: Int, protocol proto: ConnectionProtocol,
                                username: String?) -> BBSEntry {
        let defaults = UserDefaults.standard
        let font = TerminalFont(rawValue: defaults.object(forKey: "default_font") as? Int ?? 0) ?? .cp437
        let screenMode = ScreenMode(rawValue: defaults.object(forKey: "default_screen_mode") as? Int ?? 0) ?? .mode80x25
        return BBSEntry(name: host, host: host, port: port, connectionProtocol: proto,
                        username: username ?? "", screenMode: screenMode, font: font)
    }

    private static func quickConnectBoard(slot: Int) -> BBSEntry? {
        guard let id = UserDefaults.standard.string(forKey: AppPreferences.quickConnectKey(slot)), !id.isEmpty else {
            return nil
        }
        return BBSEntryStore.shared.entries.first { $0.id.uuidString == id }
    }

    // MARK: - Tab completion

    /// Tab: completes the command name, or the argument for commands that know their arguments. One
    /// match completes outright; several extend to their shared prefix, or are listed when there's
    /// nothing more to add.
    func completeInput() {
        let text = inputText
        let space = text.firstIndex(of: " ")

        let head: String
        let partial: String
        let pool: [String]
        if let space = space {
            guard let command = findCommand(String(text[text.startIndex..<space])) else { return }
            // Tab after a command with no argument list does nothing.
            if case .noArgs = command.args { return }
            head = String(text[text.startIndex...space])
            // Leading whitespace only (Windows: `.TrimStart()`) — a trailing space in the partial
            // is part of what the user typed and should still fail to match anything, not be
            // silently dropped.
            partial = String(String(text[text.index(after: space)...]).drop(while: { $0 == " " }))
            pool = candidates(for: command.args, partial: partial)
        } else {
            head = ""
            partial = text
            pool = commandNames()
        }

        var seen = Set<String>()
        let matches = pool
            .filter { $0.lowercased().hasPrefix(partial.lowercased()) }
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.lowercased() < $1.lowercased() }
        guard !matches.isEmpty else { return }

        if matches.count == 1 {
            setInput(head + matches[0] + (space == nil ? " " : ""))
            return
        }

        let common = Self.commonPrefix(matches)
        if common.count > partial.count {
            setInput(head + common)
            return
        }

        echo(text)
        write("  " + matches.joined(separator: "   "), .dim)
    }

    private func candidates(for pool: ArgPool, partial: String) -> [String] {
        switch pool {
        case .noArgs:
            return []
        case .commands:
            return commandNames()
        case .boardNames:
            return boards.map { $0.name }
        case .boardNamesAndHosts:
            return boards.map { $0.name } + boards.map { "\($0.host):\($0.port)" }
        case .dial:
            // The address first, then (after a space) the six protocol words.
            guard let space = partial.firstIndex(of: " ") else {
                return boards.map { "\($0.host):\($0.port)" }
            }
            let target = String(partial[partial.startIndex..<space])
            return Self.protocolWords.map { "\(target) \($0.name)" }
        case .quickConnect:
            guard let space = partial.firstIndex(of: " ") else {
                return ["1", "2", "3", "4"]
            }
            let slot = String(partial[partial.startIndex..<space])
            return boards.map { "\(slot) \($0.name)" } + ["\(slot) clear"]
        case .crt:
            return ["on", "off"]
        case .phosphor:
            return ["color", "green", "amber", "white"]
        case .baud:
            return ModemSpeeds.shortNames
        }
    }

    private func commandNames() -> [String] {
        Self.commands.filter { !$0.hidden }
            .flatMap { [$0.name] + $0.aliases }
            .filter { $0 != "?" }
    }

    // MARK: - Output

    private func echo(_ text: String) {
        append(Line(id: nextId(), text: text, style: .normal, isPrompt: true))
    }

    private func write(_ text: String, _ style: Style) {
        append(Line(id: nextId(), text: text, style: style, isPrompt: false))
    }

    private func append(_ line: Line) {
        lines.append(line)
        if lines.count > Self.maxOutputLines {
            lines.removeFirst(lines.count - Self.maxOutputLines)
        }
        scrollTick += 1
    }

    private func nextId() -> Int {
        nextLineId += 1
        return nextLineId
    }

    // MARK: - Parsing helpers

    /// Only these words: a number could otherwise be mistaken for a protocol.
    static let protocolWords: [(name: String, value: ConnectionProtocol)] = [
        ("telnet", .telnet),
        ("ssh", .ssh),
        ("telnets", .telnetS),
        ("ws", .webSocket),
        ("wss", .secureWebSocket),
        ("raw", .raw),
    ]

    private static func parseProtocol(_ text: String) -> ConnectionProtocol? {
        protocolWords.first { $0.name.caseInsensitiveCompare(text) == .orderedSame }?.value
    }

    /// `[user@]host[:port]`, with the protocol's default port when none is given.
    private static func parseTarget(_ text: String, protocol proto: ConnectionProtocol)
        -> (host: String, port: Int, username: String?)? {
        var rest = text
        var username: String?
        // The LAST "@": a password-free user name can't contain one, but a host never does either.
        if let at = rest.lastIndex(of: "@"), at != rest.startIndex {
            username = String(rest[rest.startIndex..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        guard let split = splitHostPort(rest) else { return nil }
        return (host: split.host, port: split.port ?? proto.defaultPort, username: username)
    }

    /// `host`, `host:port`, or `[ipv6]:port`. An unbracketed IPv6 address has more than one colon,
    /// so it is a host with no port.
    static func splitHostPort(_ text: String) -> (host: String, port: Int?)? {
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            if host.isEmpty { return nil }
            let rest = String(text[text.index(after: close)...])
            if rest.isEmpty {
                return (host: host, port: nil)
            }
            guard rest.hasPrefix(":"), let port = Int(String(rest.dropFirst())), port >= 1, port <= 65535 else {
                return nil
            }
            return (host: host, port: port)
        }

        // One colon exactly: an unbracketed IPv6 address has more, so it is all host.
        guard let colon = text.lastIndex(of: ":"), colon != text.startIndex,
              text.firstIndex(of: ":") == colon else {
            if text.isEmpty { return nil }
            return (host: text, port: nil)
        }
        guard let port = Int(String(text[text.index(after: colon)...])), port >= 1, port <= 65535 else {
            return nil
        }
        let host = String(text[text.startIndex..<colon])
        if host.isEmpty { return nil }
        return (host: host, port: port)
    }

    /// The first word and the rest of the line, both trimmed.
    private static func splitFirst(_ text: String) -> (head: String?, tail: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, nil) }
        guard let space = trimmed.firstIndex(of: " ") else { return (trimmed, nil) }
        return (String(trimmed[trimmed.startIndex..<space]),
                String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func commonPrefix(_ values: [String]) -> String {
        guard let first = values.first else { return "" }
        var length = first.count
        let firstChars = Array(first.lowercased())
        for value in values.dropFirst() {
            let chars = Array(value.lowercased())
            length = min(length, chars.count)
            var index = 0
            while index < length {
                if firstChars[index] != chars[index] {
                    length = index
                    break
                }
                index += 1
            }
        }
        return String(first.prefix(length))
    }

    // MARK: - Formatting helpers

    private static func padRight(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func padLeft(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    private static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func truncate(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max - 1)) + "\u{2026}"
    }

    /// Invariant-culture date text, like the Windows client's `CultureInfo.InvariantCulture`.
    private static func stamp(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func milliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}

// MARK: - Console networking

/// Plain POSIX sockets for the console's `ping`, `wardial` and `resolve` (spec §6): one `getaddrinfo`,
/// one TCP connect with a **3 s** timeout, then hang up. Nothing is ever sent to the board.
///
/// Not `NWConnection`: the probe has to stop the moment Ctrl+C cancels the task, and a non-blocking
/// socket polled from an `async` loop is the smallest thing that does that. The lookup runs off the
/// main thread; the poll loop runs on the cooperative pool, so `Task.sleep` carries the cancellation.
enum ConsoleNetwork {
    struct ProbeResult {
        let answered: Bool
        let milliseconds: Int
        /// Why it didn't answer: `no answer` / `refused` / `host not found` / the socket's message.
        let error: String?
    }

    struct ResolvedAddress {
        let text: String
        let isIPv6: Bool
    }

    /// A lookup failure, so `resolve` can report it as `error: <message>` like the Windows client.
    struct LookupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Endpoint {
        let family: Int32
        let socketType: Int32
        let protocolNumber: Int32
        /// The raw `sockaddr` bytes, ready for `connect`.
        let address: Data
        /// The numeric address, for display.
        let text: String
    }

    /// `lookup`'s outcome. Not `Result<[Endpoint], String>`: `Result`'s `Failure` must conform to
    /// `Error`, and a bare `String` doesn't (and isn't given `LookupError`'s throw-facing wrapping
    /// here, since `probe` just wants the raw message for `ProbeResult.error`, not a thrown error).
    private enum LookupOutcome {
        case success([Endpoint])
        case failure(String)
    }

    /// The host's addresses, IPv4 and IPv6, in the order the resolver returns them. The board's port
    /// is irrelevant here and no connection is opened.
    static func addresses(of host: String) async throws -> [ResolvedAddress] {
        let resolution: LookupOutcome = await offMainThread {
            lookup(host: host, port: nil)
        }
        switch resolution {
        case .failure(let message):
            throw LookupError(message: message)
        case .success(let endpoints):
            var seen = Set<String>()
            var unique: [ResolvedAddress] = []
            for endpoint in endpoints {
                guard seen.insert(endpoint.text).inserted else { continue }
                unique.append(ResolvedAddress(text: endpoint.text, isIPv6: endpoint.family == AF_INET6))
            }
            return unique
        }
    }

    /// One TCP call to host:port: whether it answered within `timeout`, and how long it took.
    static func probe(host: String, port: Int, timeout: TimeInterval) async throws -> ProbeResult {
        let clock = Date()
        let resolution: LookupOutcome = await offMainThread {
            lookup(host: host, port: port)
        }

        let endpoints: [Endpoint]
        switch resolution {
        case .failure(let message):
            return ProbeResult(answered: false, milliseconds: elapsed(since: clock), error: message)
        case .success(let list):
            endpoints = list
        }

        var lastError = "no answer"
        for endpoint in endpoints {
            try Task.checkCancellation()

            let descriptor = socket(endpoint.family, endpoint.socketType, endpoint.protocolNumber)
            if descriptor < 0 {
                lastError = String(cString: strerror(errno))
                continue
            }
            defer { close(descriptor) }

            let flags = fcntl(descriptor, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            }

            var pending = false
            var connected = false
            var failure: String?
            endpoint.address.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                let pointer = base.assumingMemoryBound(to: sockaddr.self)
                if Darwin.connect(descriptor, pointer, socklen_t(endpoint.address.count)) == 0 {
                    connected = true
                } else if errno == EINPROGRESS {
                    pending = true
                } else {
                    failure = reason(errno)
                }
            }

            if connected {
                return ProbeResult(answered: true, milliseconds: elapsed(since: clock), error: nil)
            }
            guard pending else {
                lastError = failure ?? "no answer"
                continue
            }

            // Wait for the socket to become writable, in short slices so Ctrl+C is felt at once.
            let deadline = Date().addingTimeInterval(timeout)
            var timedOut = false
            var socketError: String?
            while true {
                try Task.checkCancellation()
                if Date() >= deadline {
                    timedOut = true
                    break
                }

                var descriptors = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptors, 1, 0)
                if ready > 0 {
                    var pendingError: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    _ = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &pendingError, &size)
                    if pendingError == 0 {
                        return ProbeResult(answered: true, milliseconds: elapsed(since: clock), error: nil)
                    }
                    socketError = reason(pendingError)
                    break
                }
                if ready < 0 && errno != EINTR {
                    socketError = reason(errno)
                    break
                }
                try await Task.sleep(nanoseconds: 30_000_000)
            }

            lastError = timedOut ? "no answer" : (socketError ?? "no answer")
        }

        return ProbeResult(answered: false, milliseconds: elapsed(since: clock), error: lastError)
    }

    // MARK: - Helpers

    /// `getaddrinfo` blocks, so it never runs on the main thread.
    private static func offMainThread<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func lookup(host: String, port: Int?) -> LookupOutcome {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var info: UnsafeMutablePointer<addrinfo>?
        let service = port.map { String($0) }
        let status = getaddrinfo(host, service, &hints, &info)
        guard status == 0, let first = info else {
            return .failure(status == EAI_NONAME ? "host not found" : String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(info) }

        var endpoints: [Endpoint] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if let address = current.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let named = getnameinfo(address, current.pointee.ai_addrlen,
                                        &buffer, socklen_t(buffer.count),
                                        nil, 0, NI_NUMERICHOST) == 0
                endpoints.append(Endpoint(family: current.pointee.ai_family,
                                          socketType: current.pointee.ai_socktype,
                                          protocolNumber: current.pointee.ai_protocol,
                                          address: Data(bytes: address, count: Int(current.pointee.ai_addrlen)),
                                          text: named ? String(cString: buffer) : host))
            }
            node = current.pointee.ai_next
        }
        return endpoints.isEmpty ? .failure("host not found") : .success(endpoints)
    }

    private static func reason(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED: return "refused"
        case ETIMEDOUT: return "no answer"
        default: return String(cString: strerror(code))
        }
    }

    private static func elapsed(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}
