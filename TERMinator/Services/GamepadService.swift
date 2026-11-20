import CoreHaptics
import Foundation
import GameController

/// Gamepads for TRACE modules: up to four Xbox-style controllers. Reports what they do as the engine contract's pad
/// events (engine_contract.h TE_IN_PAD_*): buttons in SDL GameController order, sticks with down/right positive,
/// triggers 0..32767, and pads coming and going. While TERMinator isn't the active app the pads read as released and
/// centred (and stop rumbling), so a game in the background never sees input meant for another app.
///
/// Port of the Windows client's `Services/GamepadService.cs` (XInput). Here the pads come from Apple's GameController
/// framework, which covers Xbox, PlayStation and MFi controllers over USB and Bluetooth with no driver, and already
/// presents them in the standard layout this contract uses. Three differences worth knowing: the framework hands us
/// changes on its own (a handler per pad) rather than being polled, so there is no poll thread; rumble is Core
/// Haptics rather than two motor strengths, so the stronger motor sets the intensity; and TERMinator is sandboxed,
/// so `TERMinator.entitlements` must carry `com.apple.security.device.usb` and `.bluetooth` or not one pad is ever
/// seen -- `GCController.controllers()` comes back empty and no connect notification arrives. XInput needs no
/// permission, so nothing in the Windows master hints at this.
final class GamepadService {
    static let maxPads = 4
    private static let axisCount = 6

    /// A pad we've seen, and what was last reported for it.
    private final class Pad {
        let controller: GCController
        var buttons = [Bool](repeating: false, count: 15)
        var axes = [Int](repeating: 0, count: GamepadService.axisCount)
        var rumbleUntil: TimeInterval = 0
        /// One engine per pad, made on its first rumble and reused (Core Haptics stops the moment its engine and
        /// player are released); `engineRunning` drops when the system stops or resets it, so the next rumble
        /// starts it again. Only the newest player plays: a new rumble stops the one before.
        var haptics: CHHapticEngine?
        var engineRunning = false
        var player: CHHapticPatternPlayer?

        init(_ controller: GCController) {
            self.controller = controller
        }
    }

    private var pads = [Pad?](repeating: nil, count: maxPads)
    private let lock = NSLock()
    private var running = false
    private var observers: [NSObjectProtocol] = []

    /// A pad was plugged in (true) or removed.
    var onDeviceChanged: ((Int, Bool) -> Void)?

    /// pad, button (TE_PAD_BUTTON_*), pressed.
    var onButtonChanged: ((Int, Int, Bool) -> Void)?

    /// pad, axis (TE_PAD_AXIS_*), value.
    var onAxisChanged: ((Int, Int, Int) -> Void)?

    private var activeFlag = true

    /// Whether TERMinator is the active app. While it isn't, pads read as released and centred.
    var active: Bool {
        get { lock.lock(); defer { lock.unlock() }; return activeFlag }
        set {
            lock.lock()
            let was = activeFlag
            activeFlag = newValue
            lock.unlock()
            if !newValue {
                stopAllRumble()
            }
            if was != newValue {
                zeroOrRestore(newValue)
            }
        }
    }

    /// Starts watching for pads (a module is running).
    func start() {
        guard !running else { return }
        running = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
            [weak self] note in
            if let controller = note.object as? GCController {
                self?.add(controller)
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) {
            [weak self] note in
            if let controller = note.object as? GCController {
                self?.remove(controller)
            }
        })
        for controller in GCController.controllers() {
            add(controller)
        }
        GCController.startWirelessControllerDiscovery {}
    }

    /// Stops watching (no module is running): stops any rumble and forgets the pads.
    func stop() {
        guard running else { return }
        running = false
        GCController.stopWirelessControllerDiscovery()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        stopAllRumble(release: true)
        lock.lock()
        for index in 0..<Self.maxPads {
            if let pad = pads[index] {
                pad.controller.extendedGamepad?.valueChangedHandler = nil
            }
            pads[index] = nil
        }
        lock.unlock()
    }

    /// Tells a module that has just started about the pads already plugged in and how they are held right now,
    /// through the given callbacks (device, button, axis).
    func replay(device: (Int, Bool) -> Void, button: (Int, Int, Bool) -> Void, axis: (Int, Int, Int) -> Void) {
        lock.lock()
        let snapshot = pads.enumerated().compactMap { index, pad in pad.map { (index, $0.buttons, $0.axes) } }
        lock.unlock()
        for (index, buttons, axes) in snapshot {
            device(index, true)
            for (number, held) in buttons.enumerated() where held {
                button(index, number, true)
            }
            for (number, value) in axes.enumerated() where value != 0 {
                axis(index, number, value)
            }
        }
    }

    /// Rumbles a pad: low (heavy) and high (light) motors 0..32767 for ms milliseconds; 0 ms stops it.
    func rumble(pad index: Int, low: Int, high: Int, ms: Int) {
        guard index >= 0, index < Self.maxPads else { return }
        lock.lock()
        let pad = pads[index]
        let allowed = activeFlag || ms <= 0
        lock.unlock()
        guard let pad, allowed else { return }

        if ms <= 0 {
            stopRumble(pad)
            return
        }
        guard let engine = engine(for: pad) else {
            return   // a pad without haptics (many third-party ones): nothing to do
        }
        // One steady buzz at the strength the module asked for, for as long as it asked for. Core Haptics has no
        // two-motor API, so the stronger of the two motors sets the intensity -- what a player actually feels.
        let seconds = Double(ms) / 1000.0
        let strength = min(max(Float(max(low, high)) / 32767.0, 0), 1)
        do {
            lock.lock()
            let running = pad.engineRunning
            lock.unlock()
            if !running {
                try engine.start()
                lock.lock()
                pad.engineRunning = true
                lock.unlock()
            }
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
            ], relativeTime: 0, duration: seconds)
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            lock.lock()
            let previous = pad.player
            pad.player = player
            pad.rumbleUntil = Date().timeIntervalSince1970 + seconds
            lock.unlock()
            try? previous?.stop(atTime: CHHapticTimeImmediate)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            return
        }
        // Stop it ourselves as well as by duration, so nothing is left running if the pattern outlives its time
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak pad] in
            guard let self, let pad else { return }
            self.lock.lock()
            let due = pad.rumbleUntil != 0 && Date().timeIntervalSince1970 >= pad.rumbleUntil - 0.01
            self.lock.unlock()
            if due {
                self.stopRumble(pad)
            }
        }
    }

    /// The pad's haptic engine, made once and kept for every later rumble.
    private func engine(for pad: Pad) -> CHHapticEngine? {
        lock.lock()
        if let engine = pad.haptics {
            lock.unlock()
            return engine
        }
        lock.unlock()
        guard let engine = pad.controller.haptics?.createEngine(withLocality: .default) else { return nil }
        engine.isAutoShutdownEnabled = true   // idles down between rumbles; stoppedHandler says so
        engine.stoppedHandler = { [weak self, weak pad] _ in
            guard let self, let pad else { return }
            self.lock.lock()
            pad.engineRunning = false
            pad.player = nil
            self.lock.unlock()
        }
        engine.resetHandler = { [weak self, weak pad] in
            // The haptic server restarted: players made before are dead, and the engine must be started again
            guard let self, let pad else { return }
            self.lock.lock()
            pad.engineRunning = false
            pad.player = nil
            pad.rumbleUntil = 0
            self.lock.unlock()
        }
        lock.lock()
        pad.haptics = engine
        lock.unlock()
        return engine
    }

    /// Stops a pad's rumble; `release` also stops and drops its engine (the pad or the module went away).
    private func stopRumble(_ pad: Pad, release: Bool = false) {
        lock.lock()
        let player = pad.player
        let engine = release ? pad.haptics : nil
        pad.player = nil
        pad.rumbleUntil = 0
        if release {
            pad.haptics = nil
            pad.engineRunning = false
        }
        lock.unlock()
        try? player?.stop(atTime: CHHapticTimeImmediate)
        engine?.stop(completionHandler: nil)
    }

    private func stopAllRumble(release: Bool = false) {
        lock.lock()
        let rumbling = pads.compactMap { $0 }.filter { $0.rumbleUntil != 0 || (release && $0.haptics != nil) }
        lock.unlock()
        for pad in rumbling {
            stopRumble(pad, release: release)
        }
    }

    /// Which slot a pad sits in, or nil once it has been removed.
    private func index(of pad: Pad) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return pads.firstIndex { $0 === pad }
    }

    // MARK: - Pads coming and going

    private func add(_ controller: GCController) {
        guard controller.extendedGamepad != nil else { return }   // not a gamepad (a remote, a racing wheel)
        lock.lock()
        if pads.contains(where: { $0?.controller === controller }) {
            lock.unlock()
            return
        }
        guard let slot = pads.firstIndex(where: { $0 == nil }) else {
            lock.unlock()
            return   // four already
        }
        let pad = Pad(controller)
        pads[slot] = pad
        lock.unlock()
        // One handler for the whole pad: read everything and report only what moved (as XInput's polling does)
        controller.extendedGamepad?.valueChangedHandler = { [weak self] gamepad, _ in
            self?.readPad(slot: slot, gamepad: gamepad)
        }
        onDeviceChanged?(slot, true)
        readPad(slot: slot, gamepad: controller.extendedGamepad!)   // how it is held right now
    }

    private func remove(_ controller: GCController) {
        lock.lock()
        guard let slot = pads.firstIndex(where: { $0?.controller === controller }), let pad = pads[slot] else {
            lock.unlock()
            return
        }
        // Unplugged: let go of everything it was holding, then say it's gone
        var released: [(Int, Int, Bool)] = []
        var centred: [(Int, Int, Int)] = []
        for (number, held) in pad.buttons.enumerated() where held {
            released.append((slot, number, false))
        }
        for (number, value) in pad.axes.enumerated() where value != 0 {
            centred.append((slot, number, 0))
        }
        pad.controller.extendedGamepad?.valueChangedHandler = nil
        pads[slot] = nil
        lock.unlock()
        stopRumble(pad, release: true)
        for (pad, button, pressed) in released {
            onButtonChanged?(pad, button, pressed)
        }
        for (pad, axis, value) in centred {
            onAxisChanged?(pad, axis, value)
        }
        onDeviceChanged?(slot, false)
    }

    // MARK: - Reading one pad

    /// The contract's button numbers (TE_PAD_BUTTON_*) against GameController's names, in the Xbox layout.
    private static func buttonList(_ g: GCExtendedGamepad) -> [(Int, GCControllerButtonInput?)] {
        [
            (0, g.buttonA), (1, g.buttonB), (2, g.buttonX), (3, g.buttonY),
            (4, g.buttonOptions), (5, g.buttonHome), (6, g.buttonMenu),
            (7, g.leftThumbstickButton), (8, g.rightThumbstickButton),
            (9, g.leftShoulder), (10, g.rightShoulder),
            (11, g.dpad.up), (12, g.dpad.down), (13, g.dpad.left), (14, g.dpad.right),
        ]
    }

    /// GameController gives -1...1; the contract wants -32768..32767 (the callers flip y, which points up here).
    private static func stick(_ value: Float) -> Int {
        let v = min(max(value, -1), 1)
        return Int((v < 0 ? v * 32768 : v * 32767).rounded())
    }

    private static func trigger(_ value: Float) -> Int {
        Int((min(max(value, 0), 1) * 32767).rounded())
    }

    private func readPad(slot: Int, gamepad: GCExtendedGamepad) {
        lock.lock()
        guard let pad = pads[slot] else {
            lock.unlock()
            return
        }
        let reportAsHeld = activeFlag
        var buttonChanges: [(Int, Int, Bool)] = []
        var axisChanges: [(Int, Int, Int)] = []

        // Store what we REPORT, not what the pad is really doing: while TERMinator is inactive everything reads as
        // released, and keeping the real state here would make the next change report a redundant event and hand a
        // module that starts now a held button it should not see. Windows does the same (`buttons = _active ? ...`).
        for (number, input) in Self.buttonList(gamepad) {
            let pressed = (input?.isPressed ?? false) && reportAsHeld
            if pad.buttons[number] != pressed {
                pad.buttons[number] = pressed
                buttonChanges.append((slot, number, pressed))
            }
        }

        let values = [
            Self.stick(gamepad.leftThumbstick.xAxis.value),
            -Self.stick(gamepad.leftThumbstick.yAxis.value),     // y points up here, down in the contract
            Self.stick(gamepad.rightThumbstick.xAxis.value),
            -Self.stick(gamepad.rightThumbstick.yAxis.value),
            Self.trigger(gamepad.leftTrigger.value),
            Self.trigger(gamepad.rightTrigger.value),
        ]
        for (number, raw) in values.enumerated() {
            let value = reportAsHeld ? max(min(raw, 32767), -32768) : 0
            let old = pad.axes[number]
            // Sticks jitter by a few counts at rest: skip changes too small to matter, but always report reaching
            // the centre or an end, so a released stick reads exactly 0
            let edge = value == 0 || value == 32767 || value == -32768
            if value == old || (!edge && abs(value - old) < 128) {
                continue
            }
            pad.axes[number] = value
            axisChanges.append((slot, number, value))
        }
        lock.unlock()

        for (pad, button, pressed) in buttonChanges {
            onButtonChanged?(pad, button, pressed)
        }
        for (pad, axis, value) in axisChanges {
            onAxisChanged?(pad, axis, value)
        }
    }

    /// TERMinator became active or inactive: report everything as released and centred while it isn't, and what the
    /// pads are really doing again when it is. A game in the background must not act on input meant for another app.
    ///
    /// Coming back needs a fresh read rather than a replay of what was stored: `readPad` records the zeros it
    /// reported while we were away, and GameController only calls us when something CHANGES -- so a button held
    /// across the switch would otherwise stay invisible until the player let go of it.
    private func zeroOrRestore(_ active: Bool) {
        if active {
            lock.lock()
            let live = pads.compactMap { pad in pad.map { ($0, $0.controller.extendedGamepad) } }
            lock.unlock()
            for (pad, gamepad) in live {
                guard let gamepad, let slot = index(of: pad) else { continue }
                readPad(slot: slot, gamepad: gamepad)
            }
            return
        }
        lock.lock()
        var buttonChanges: [(Int, Int, Bool)] = []
        var axisChanges: [(Int, Int, Int)] = []
        for (slot, pad) in pads.enumerated() {
            guard let pad else { continue }
            for (number, held) in pad.buttons.enumerated() where held {
                // Store the release we are REPORTING, exactly as readPad does. Leaving the real state here broke
                // both directions: `replay()` would hand a module starting now a button that is supposed to read
                // as released, and coming back would find the stored state already matching the held button, so
                // the re-press was never reported and the module lost the button for good. Windows has no such
                // path -- its poll writes the zeros it reports straight into PadState.
                pad.buttons[number] = false
                buttonChanges.append((slot, number, false))
            }
            for (number, value) in pad.axes.enumerated() where value != 0 {
                pad.axes[number] = 0
                axisChanges.append((slot, number, 0))
            }
        }
        lock.unlock()
        for (pad, button, pressed) in buttonChanges {
            onButtonChanged?(pad, button, pressed)
        }
        for (pad, axis, value) in axisChanges {
            onAxisChanged?(pad, axis, value)
        }
    }

    deinit {
        stop()
    }
}
