import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Rainwire file drops (files=1; Rainwire docs/WINDOWS.md "File drops", docs/FILES_GFX.md "Step 3d"), the
/// terminal's side, for both places files can be dropped:
///   - desk windows (checklist item 13): Finder files dropped on a Rainwire window or the desktop, and a file row
///     dragged out of a window and let go on Finder;
///   - the Files TRACE module (module id rwfiles): Finder files dropped on its picture, and a row dragged out of it
///     once the board armed it with DragFile;
///   - Files as a Rainwire scene (scenes version 5, Views/RainwireScene.swift's third extension): the same,
///     module=rwfiles with scene=<block> added: files dropped on a P_DROP block, a P_DRAG row taken out of the window.
///
/// In: one FileOffer per file; the paths are kept by n. FileGo names the ones to send: the next ZMODEM upload the
/// board starts (its ZRINIT after Suspend) sends exactly those, in that order, with no file picker. FileNo shows its
/// reason. A batch nobody answers is forgotten after 2 minutes. One batch at a time (FileGo carries no batch id).
///
/// Out: the OS drag is an NSFilePromiseProvider (the Mac's lazy file: the target asks for the bytes only after the
/// drop). Let go on a target that took it (the drag session ends with an operation, or the target asks the promise
/// to write, whichever comes first): DropOut. FileGet arms the next ZMODEM download into a fresh temporary folder,
/// with no dialog but the transfer window's progress; the promise's write waits for it and then copies the file to
/// where it was dropped. FileNo: the reason, and the target gets an error.
///
/// Port of the Windows client's `RainwireWm/RainwireFileDrops.cs` + `OsFileDrag.cs`. macOS differences:
/// * The OS drag is not modal (Windows' DoDragDrop is): it starts, and `draggingSession(_:endedAt:operation:)` says
///   how it ended. Nothing has to pump a nested loop while waiting, so there is no DrainMessages/Wait here; the
///   promise's completion handler is simply called when the file is in.
/// * A desk drag's real name comes in FileGet, after the drop, but Finder has already asked the promise for a name
///   (the drag label's). The file is then written under the real name beside the promised URL (Windows waits for
///   FileGet inside the drop instead); if that fails, under the promised name.
/// * WmSession's closures, RainwireDesk.dragOutOfWindow and TraceSessionManager.layerViewOpened are wired here
///   (Windows: constructor events); toast/send/receive come from TerminalView (`attach`).
final class RainwireFileDrops: NSObject {
    static let shared = RainwireFileDrops()

    static let filesModule = "rwfiles"
    private static let batchLife: TimeInterval = 120
    private static let armLife: TimeInterval = 60

    private var session: WmSession { RainwireDesk.shared.session }

    private var toast: (String) -> Void = { _ in }
    private var runSend: ([String]) -> Void = { _ in }
    private var runReceive: (URL, @escaping (Bool) -> Void) -> Void = { _, done in done(false) }

    // ---- in ----
    private final class Batch {
        let paths: [String]
        var answered = Set<Int>()
        let at = Date()

        init(paths: [String]) {
            self.paths = paths
        }
    }
    private var batch: Batch?
    private var pendingSend: [String]?
    private var pendingSendAt = Date.distantPast

    // ---- out ----
    private enum OutState { case dragging, dropSent, got, receiving, done, failed }
    private final class Out {
        var name = ""
        var size: Int64 = -1
        var nameKnown = false          // from DragFile or FileGet, not a guess from the drag label
        var state = OutState.dragging
        var stateAt = Date()
        var tempDir: URL?
        var filePath: URL?
        let sendDropOut: () -> Void
        /// Promise writes waiting for the file (normally one).
        var promised: [(url: URL, completion: (Error?) -> Void)] = []
        /// The name the promise gives the target, read on the promise's queue.
        private let lock = NSLock()
        private var promiseName = ""

        init(name: String, size: Int64, nameKnown: Bool, sendDropOut: @escaping () -> Void) {
            self.name = name
            self.size = size
            self.nameKnown = nameKnown
            self.sendDropOut = sendDropOut
            self.promiseName = name
        }

        var nameForPromise: String {
            lock.lock()
            defer { lock.unlock() }
            return promiseName
        }

        func setName(_ n: String) {
            name = n
            lock.lock()
            promiseName = n
            lock.unlock()
        }
    }
    private var out: Out?
    private var armed: (name: String, size: Int64, at: Date)?   // DragFile ok=1 for the Files module
    private var osDragging = false
    private var dragAfter: (() -> Void)?
    private var dragOut: Out?

    private var reasons: [(text: String, at: Date)] = []
    private var tidyTimer: Timer?
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "TERMinator file promises"
        q.qualityOfService = .userInitiated
        return q
    }()

    private override init() {
        super.init()
        let s = RainwireDesk.shared.session
        s.fileGo = { [weak self] ns in self?.onFileGo(ns) }
        s.fileNo = { [weak self] n, from, reason in self?.onFileNo(n, from, reason) }
        s.fileGet = { [weak self] from, name, size in self?.onFileGet(from, name, size) }
        s.dragFile = { [weak self] module, ok, name, size, reason in
            self?.onDragFile(module, ok, name, size, reason)
        }
        RainwireDesk.shared.dragOutOfWindow = { [weak self] from, x, y, label, view, event in
            self?.deskDragOut(from, x, y, label, view, event) ?? false
        }
        TraceSessionManager.shared.layerViewOpened = { [weak self] id, view in
            self?.moduleLayerOpened(id, view)
        }
        // Files as a scene (Windows: AttachScene): its drop targets and dragged rows go the module's way
        s.dragFileScene = { [weak self] row, ok, label, hint in self?.onDragFileScene(row, ok, label, hint) }
        RainwireMenuView.shared.sceneDragLeftWindow = { [weak self] row, event in
            guard let self = self, let a = self.armedNow() else { return }
            self.sceneDragOut(row, a.name, a.size, event)
        }

        tidyTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tidy()
        }
        DispatchQueue.global(qos: .utility).async {
            RainwireFileDrops.cleanTemp(olderThan: 12 * 3600)
        }
    }

    /// The terminal's side (TerminalView.onAppear): a toast (FileNo reasons), the ZMODEM send of these paths now (the
    /// board's ZRINIT has arrived), and the ZMODEM receive into this folder now, calling back true when it finished
    /// whole.
    func attach(toast: @escaping (String) -> Void, runSend: @escaping ([String]) -> Void,
                runReceive: @escaping (URL, @escaping (Bool) -> Void) -> Void) {
        self.toast = toast
        self.runSend = runSend
        self.runReceive = runReceive
    }

    /// A module layer view was made: watch the Files module's for drags leaving the window.
    private func moduleLayerOpened(_ id: String, _ layer: EngineHostLayerView) {
        guard id.caseInsensitiveCompare(Self.filesModule) == .orderedSame else { return }
        layer.pointerLeftWindow = { [weak self] l, event in
            guard let self = self, let a = self.armedNow() else { return }
            self.moduleDragOut(l, a.name, a.size, event)
        }
    }

    /// The OS drag left TERMinator, or ended: the scene's drop target goes dark.
    func dragLeft() {
        RainwireMenuView.shared.sceneDropHover(0)
    }

    /// The connection went: forget everything.
    func reset() {
        batch = nil
        pendingSend = nil
        armed = nil
        if let o = out, o.state != .done && o.state != .failed {
            setOut(o, .failed)
        }
        out = nil
    }

    private func tidy() {
        let now = Date()
        if let b = batch, now.timeIntervalSince(b.at) > Self.batchLife {
            batch = nil
        }
        if pendingSend != nil && now.timeIntervalSince(pendingSendAt) > Self.batchLife {
            pendingSend = nil
        }
        if let a = armed, now.timeIntervalSince(a.at) > Self.armLife {
            armed = nil
        }
        // A drop the board never answered, or a FileGet whose transfer never started
        if let o = out, (o.state == .dropSent && now.timeIntervalSince(o.stateAt) > 45)
            || (o.state == .got && now.timeIntervalSince(o.stateAt) > 90) {
            setOut(o, .failed)
            toast("The board didn't send the file")
        }
    }

    private func showReason(_ reason: String) {
        if reason.isEmpty {
            return
        }
        let now = Date()
        reasons.removeAll { now.timeIntervalSince($0.at) > 6 }
        reasons.append((reason, now))
        toast(reasons.suffix(4).map { $0.text }.joined(separator: "\n"))
    }

    // MARK: - In: Finder files dropped on a window, the desktop or the Files module

    private enum Target { case nowhere, module, desk, scene }

    /// What's under a point in window coordinates (NSDraggingInfo.draggingLocation).
    private func targetAt(_ windowPoint: NSPoint) -> (kind: Target, id: Int, x: Int, y: Int) {
        if let t = RainwireMenuView.shared.sceneDropTarget(windowPoint: windowPoint) {   // Files as a scene: a P_DROP block
            return (.scene, Int(t.id), Int(t.at.x), Int(t.at.y))
        }
        if let layer = TraceSessionManager.shared.layerFor(Self.filesModule), layer.window != nil,
           !layer.isHiddenOrHasHiddenAncestor, let p = layer.framePoint(windowPoint: windowPoint) {
            return (.module, 0, p.x, p.y)
        }
        if session.active && !session.suspended, let desk = RainwireDesk.shared.layer, desk.window != nil,
           !desk.isHidden {
            let t = desk.dropTarget(desk.convert(windowPoint, from: nil))
            return (.desk, t.to, t.x, t.y)
        }
        return (.nowhere, 0, 0, 0)
    }

    /// draggingEntered/Updated with files: whether they can be dropped here (a scene's target lit while so).
    func canTake(at windowPoint: NSPoint) -> Bool {
        let t = osDragging ? (kind: Target.nowhere, id: 0, x: 0, y: 0) : targetAt(windowPoint)
        RainwireMenuView.shared.sceneDropHover(t.kind == .scene ? UInt16(t.id) : 0)
        return !osDragging && t.kind != .nowhere
    }

    /// Files dropped from Finder. True when they were ours to take (offered, or refused with a reason).
    func drop(at windowPoint: NSPoint, urls: [URL]) -> Bool {
        let t = targetAt(windowPoint)
        RainwireMenuView.shared.sceneDropHover(0)
        if t.kind == .nowhere || osDragging {
            return false
        }
        if let b = batch, Date().timeIntervalSince(b.at) < Self.batchLife {
            toast("Still waiting on the board for the last files dropped")
            return true
        }
        if pendingSend != nil || (out.map { $0.state == .got || $0.state == .receiving } ?? false) {
            toast("A transfer is waiting to start: drop the files again after it")
            return true
        }
        var paths: [String] = []
        var folders = 0
        for url in urls where url.isFileURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    folders += 1
                } else {
                    paths.append(url.path)
                }
            }
        }
        if paths.isEmpty {
            toast(folders > 0 ? "Folders can't be uploaded: drop the files in them" : "Nothing to upload")
            return true
        }
        if folders > 0 {
            toast("Folders were left out: only files can be uploaded")
        }
        batch = Batch(paths: paths)
        let module: String? = t.kind == .module || t.kind == .scene ? Self.filesModule : nil
        let scene = t.kind == .scene ? t.id : 0
        for (i, path) in paths.enumerated() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            session.fileOffer(i + 1, paths.count, scene > 0 ? 0 : t.id, module, t.x, t.y,
                              (path as NSString).lastPathComponent, size, scene: scene)
        }
        return true
    }

    private func onFileGo(_ ns: [Int]) {
        guard let b = batch else { return }
        var send: [String] = []
        for n in ns {
            if n < 1 || n > b.paths.count || !b.answered.insert(n).inserted {
                continue
            }
            send.append(b.paths[n - 1])
        }
        if b.answered.count >= b.paths.count {
            batch = nil
        }
        if send.isEmpty {
            return
        }
        pendingSend = send
        pendingSendAt = Date()
    }

    private func onFileNo(_ n: Int, _ from: Int, _ reason: String) {
        if n > 0 && from < 0 {
            if let b = batch, n <= b.paths.count {
                b.answered.insert(n)
                if b.answered.count >= b.paths.count {
                    batch = nil
                }
            }
            showReason(reason.isEmpty ? "A file was refused" : reason)
            return
        }
        // The answer to a DropOut
        if let o = out, o.state == .dropSent || o.state == .dragging {
            setOut(o, .failed)
        }
        showReason(reason.isEmpty ? "That file can't be downloaded" : reason)
    }

    // MARK: - ZMODEM: the board's transfer starts; run it with no picker

    /// ZMODEM auto-detect fired (-100 the board sends, -101 it receives). True when a file drop owns this transfer
    /// (it then runs without asking); false for a normal transfer.
    func handleZmodem(_ direction: Int) -> Bool {
        RainwireDesk.shared.poll()   // FileGo / FileGet came just before the transfer: take them first
        if direction == -101, let paths = pendingSend {
            pendingSend = nil
            runSend(paths)
            return true
        }
        if direction == -100, let o = out, o.state == .got {
            let dir = Self.tempRoot.appendingPathComponent(UUID().uuidString.replacingOccurrences(of: "-", with: "")
                .lowercased())
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                print("RainwireFileDrops: temp folder: \(error.localizedDescription)")
                setOut(o, .failed)
                return false   // the normal download takes it instead
            }
            o.tempDir = dir
            setOut(o, .receiving)
            runReceive(dir) { [weak self] ok in
                guard let self = self, self.out === o, o.state == .receiving else { return }
                let file = Self.largestFile(in: dir)
                if ok, let file = file {
                    o.filePath = file
                    self.setOut(o, .done)
                } else {
                    self.setOut(o, .failed)
                    self.toast("\(o.name) didn't arrive")
                }
            }
            return true
        }
        return false
    }

    private static func largestFile(in dir: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey],
                                                                  options: [])) ?? []
        return files.max { a, b in
            ((try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                < ((try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static var tempRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TERMinator-drops", isDirectory: true)
    }

    /// Removes received drop files older than age (Finder has long since copied them).
    private static func cleanTemp(olderThan age: TimeInterval) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: [.creationDateKey],
                                                     options: []) else { return }
        for d in dirs {
            let created = (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            if Date().timeIntervalSince(created) > age {
                try? fm.removeItem(at: d)   // still open: next time
            }
        }
    }

    // MARK: - Out: a drag leaves the window and is let go on Finder

    private func armedNow() -> (name: String, size: Int64)? {
        guard let a = armed, Date().timeIntervalSince(a.at) <= Self.armLife else { return nil }
        return (a.name, a.size)
    }

    private func onDragFile(_ module: String, _ ok: Bool, _ name: String, _ size: Int64, _ reason: String) {
        guard module.caseInsensitiveCompare(Self.filesModule) == .orderedSame else { return }
        if !ok || name.isEmpty {
            armed = nil
            return   // the module shows the reason itself
        }
        armed = (name, size, Date())
        // The pointer may already be outside, the button still down. Not from inside the WM poll's pass.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let a = self.armedNow(),
                  let layer = TraceSessionManager.shared.layerFor(Self.filesModule), layer.leftHeldOutsideWindow(),
                  let event = layer.lastDragEvent else { return }
            self.moduleDragOut(layer, a.name, a.size, event)
        }
    }

    /// DragFile for a scene's row: the label by the pointer (or the drag ends), and the OS drag at once when the
    /// pointer is already outside with the button down.
    private func onDragFileScene(_ row: Int, _ ok: Bool, _ label: String, _ hint: String) {
        let menu = RainwireMenuView.shared
        menu.sceneDragAnswer(UInt16(clamping: row), ok, label, hint)
        if !ok {
            return
        }
        DispatchQueue.main.async { [weak self] in   // not from inside the WM poll's pass (onDragFile)
            guard let self = self, let a = self.armedNow(), Int(menu.sceneDragRow) == row, menu.sceneDragHeldOutside(),
                  let event = menu.sDragEvent else { return }
            self.sceneDragOut(menu.sceneDragRow, a.name, a.size, event)
        }
    }

    private func sceneDragOut(_ row: UInt16, _ name: String, _ size: Int64, _ event: NSEvent) {
        if osDragging {
            return
        }
        armed = nil   // one drag per arming
        let module = Self.filesModule, menu = RainwireMenuView.shared
        _ = runOsDrag(name, size, nameKnown: true,
                      sendDropOut: { [weak self] in self?.session.dropOutModule(module, scene: Int(row)) },
                      view: menu, event: event,
                      before: { menu.sceneBeginExternalDrag() },
                      after: { menu.sceneEndExternalDrag() })
    }

    private func moduleDragOut(_ layer: EngineHostLayerView, _ name: String, _ size: Int64, _ event: NSEvent) {
        if osDragging {
            return
        }
        armed = nil   // one drag per arming
        let module = Self.filesModule
        _ = runOsDrag(name, size, nameKnown: true, sendDropOut: { [weak self] in self?.session.dropOutModule(module) },
                      view: layer, event: event,
                      before: { [weak layer] in layer?.beginExternalDrag() },
                      after: { [weak layer] in layer?.endExternalDrag() })
    }

    /// A desk window's drag (DragInfo ok) left the TERMinator window: the OS drag. True if it started.
    private func deskDragOut(_ from: Int, _ x: Int, _ y: Int, _ label: String, _ view: NSView, _ event: NSEvent) -> Bool {
        if osDragging {
            return false
        }
        let guess = Self.safeName(label)
        _ = runOsDrag(guess, -1, nameKnown: false, sendDropOut: { [weak self] in self?.session.dropOut(from, x, y) },
                      view: view, event: event, before: nil, after: nil)
        return true
    }

    private func runOsDrag(_ name: String, _ size: Int64, nameKnown: Bool, sendDropOut: @escaping () -> Void,
                           view: NSView, event: NSEvent, before: (() -> Void)?, after: (() -> Void)?) -> Bool {
        if let o = out, o.state == .dropSent || o.state == .got || o.state == .receiving {
            toast("Another file is still on its way: try again when it's done")
            return false
        }
        let o = Out(name: name, size: size, nameKnown: nameKnown, sendDropOut: sendDropOut)
        out = o

        let ext = (name as NSString).pathExtension
        let type = (ext.isEmpty ? nil : UTType(filenameExtension: ext)) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = o
        let item = NSDraggingItem(pasteboardWriter: provider)
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 48, height: 48)
        let p = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48), contents: icon)

        osDragging = true
        dragOut = o
        dragAfter = after
        before?()
        let drag = view.beginDraggingSession(with: [item], event: event, source: self)
        drag.animatesToStartingPositionsOnCancelOrFail = false
        return true
    }

    /// Let go over a target that took it (or the target asked for the file): send DropOut, once.
    private func dropped(_ o: Out) {
        guard out === o, o.state == .dragging else { return }
        setOut(o, .dropSent)
        o.sendDropOut()
    }

    private func onFileGet(_ from: Int, _ name: String, _ size: Int64) {
        guard let o = out, o.state == .dropSent else {
            return   // nothing waiting (the drag's target gave up): the board's transfer gets the normal window
        }
        let real = Self.safeName(name)
        if !real.isEmpty && real != "download" {
            o.setName(real)
            o.nameKnown = true
        }
        if size >= 0 {
            o.size = size
        }
        setOut(o, .got)
    }

    private func setOut(_ o: Out, _ state: OutState) {
        o.state = state
        o.stateAt = Date()
        if state == .done || state == .failed {
            settle(o)
        }
    }

    /// The file is in (or isn't coming): answer every promise write waiting for it.
    private func settle(_ o: Out) {
        guard !o.promised.isEmpty else { return }
        let waiting = o.promised
        o.promised.removeAll()
        let ok = o.state == .done
        let source = o.filePath
        let realName = o.name
        let failName = o.name
        promiseQueue.addOperation {
            for w in waiting {
                if ok, let source = source {
                    w.completion(RainwireFileDrops.deliver(source, to: w.url, realName: realName))
                } else {
                    w.completion(NSError(domain: "TERMinator", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "\(failName) didn't arrive"]))
                }
            }
        }
    }

    /// Copies the received file to where it was dropped: under its real name beside the promised URL when the
    /// promise had to guess the name (a desk drag), else (or if that fails) to the promised URL itself.
    private static func deliver(_ source: URL, to url: URL, realName: String) -> Error? {
        let fm = FileManager.default
        if !realName.isEmpty && realName != url.lastPathComponent {
            let alt = url.deletingLastPathComponent().appendingPathComponent(realName)
            if !fm.fileExists(atPath: alt.path), (try? fm.copyItem(at: source, to: alt)) != nil {
                return nil
            }
        }
        do {
            try fm.copyItem(at: source, to: url)
            return nil
        } catch {
            return error
        }
    }

    /// A name that's safe as a file name in a folder ("download" if nothing is left).
    private static func safeName(_ text: String) -> String {
        var name = text
        if let cut = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: cut)...])
        }
        name = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0 != ":" && $0.value != 0x7F }
            .map(Character.init))
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix(".") {
            name.removeLast()
        }
        return name.isEmpty ? "download" : name
    }

    // MARK: - Where the pointer is

    /// True when the pointer is outside the TERMinator window that holds view.
    static func pointerOutsideWindow(_ view: NSView) -> Bool {
        guard let w = view.window else { return false }
        return !w.frame.contains(NSEvent.mouseLocation)
    }
}

// MARK: - The OS drag (Windows: OsFileDrag.cs)

extension RainwireFileDrops: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Let go back inside TERMinator is a cancel: nothing is sent
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        osDragging = false
        let after = dragAfter
        dragAfter = nil
        let o = dragOut
        dragOut = nil
        after?()
        if let o = o {
            if operation != [] {
                dropped(o)
            } else if o.state == .dragging && out === o {
                out = nil   // let go back in TERMinator, or cancelled: nothing was sent
            }
        }
        DispatchQueue.global(qos: .utility).async {
            RainwireFileDrops.cleanTemp(olderThan: 10 * 60)
        }
    }
}

extension RainwireFileDrops: NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? Out)?.nameForPromise ?? "download"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }

    /// The target wants the file (after the drop; hovering never downloads). It waits until the ZMODEM receive ends.
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let o = filePromiseProvider.userInfo as? Out else {
            completionHandler(NSError(domain: "TERMinator", code: 2, userInfo: nil))
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completionHandler(NSError(domain: "TERMinator", code: 2, userInfo: nil))
                return
            }
            if o.state == .dragging {
                if self.out === o {
                    self.dropped(o)
                } else {
                    self.setOut(o, .failed)
                }
            }
            o.promised.append((url, completionHandler))
            if o.state == .done || o.state == .failed {
                self.settle(o)
            }
        }
    }
}

// MARK: - The drop target (Windows: MainWindow's AllowDrop + PreviewDragOver/PreviewDrop)

/// Takes Finder files dropped over the terminal area for RainwireFileDrops: the Files TRACE module's picture or the
/// Rainwire desk. Registered only for file URLs, so other drags are none of its business, and invisible to the mouse
/// (hitTest nil): clicks, moves and the wheel go to whatever is under it. AppKit finds drag destinations by their
/// registered types, not by hitTest.
final class RainwireFileDropView: NSView {
    private static let readOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: Self.readOptions) else {
            return []
        }
        return RainwireFileDrops.shared.canTake(at: sender.draggingLocation) ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    // Windows' PreviewDragLeave: a lit scene drop target goes dark
    override func draggingExited(_ sender: NSDraggingInfo?) { RainwireFileDrops.shared.dragLeft() }
    override func draggingEnded(_ sender: NSDraggingInfo) { RainwireFileDrops.shared.dragLeft() }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { operation(sender) != [] }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: Self.readOptions)
                as? [URL], !urls.isEmpty else { return false }
        return RainwireFileDrops.shared.drop(at: sender.draggingLocation, urls: urls)
    }
}

/// SwiftUI wrapper: the drop target over the whole terminal area, above the TRACE layer and the desk.
struct RainwireFileDropTarget: NSViewRepresentable {
    func makeNSView(context: Context) -> RainwireFileDropView {
        RainwireFileDropView(frame: .zero)
    }

    func updateNSView(_ nsView: RainwireFileDropView, context: Context) {}
}
