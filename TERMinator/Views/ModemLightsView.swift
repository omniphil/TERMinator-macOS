import SwiftUI

/// The front panel of an external modem, in the US Robotics Sportster order: HS AA CD OH RD SD TR MR, a red LED over
/// each label. Same look as the Windows and Linux clients: 7 pt LEDs 5 pt apart, lit #FF3B2F with a glow, dark
/// #3A1212, 9 pt monospaced labels in #777799.
struct ModemLightsView: View {
    static let labels = ["HS", "AA", "CD", "OH", "RD", "SD", "TR", "MR"]

    @ObservedObject var model: ModemLightsModel

    private static let litColor = Color(red: 0xFF / 255, green: 0x3B / 255, blue: 0x2F / 255)
    private static let darkColor = Color(red: 0x3A / 255, green: 0x12 / 255, blue: 0x12 / 255)
    private static let glowColor = Color(red: 0xFF / 255, green: 0x30 / 255, blue: 0x20 / 255)
    private static let labelColor = Color(red: 0x77 / 255, green: 0x77 / 255, blue: 0x99 / 255)

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<Self.labels.count, id: \.self) { index in
                let on = model.lit[index]
                VStack(spacing: 1) {
                    Circle()
                        .fill(on ? Self.litColor : Self.darkColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: on ? Self.glowColor.opacity(0.9) : .clear, radius: 4)
                    Text(Self.labels[index])
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Self.labelColor)
                }
            }
        }
        .help("HS high speed \u{00B7} AA auto answer \u{00B7} CD carrier detect \u{00B7} OH off hook \u{00B7} "
            + "RD receive data \u{00B7} SD send data \u{00B7} TR terminal ready \u{00B7} MR modem ready")
    }
}

/// Drives the lights from the live connection every 50 ms: RD / SD light when the received / sent byte counter moved
/// since the last tick (lit 3 ticks in 4 while data keeps flowing, held 90 ms after), CD, OH, TR and MR while connected,
/// AA never, HS when the effective speed is 0 (full speed) or 9600 bps and up. All dark when not connected.
final class ModemLightsModel: ObservableObject {
    @Published private(set) var lit = [Bool](repeating: false, count: 8)

    /// Current (sent, received) byte counters, or nil when not connected. Set by the owner.
    var readCounters: () -> (sent: Int64, received: Int64)? = { nil }

    /// The speed incoming data is metered at, in bps; 0 = full speed. Set by the owner.
    var readEffectiveBps: () -> Int = { 0 }

    private var timer: Timer?
    private var lastRx: Int64 = 0
    private var lastTx: Int64 = 0
    private var rxLitUntil: TimeInterval = 0
    private var txLitUntil: TimeInterval = 0

    func start() {
        stop()
        lastRx = 0
        lastTx = 0
        rxLitUntil = 0
        txLitUntil = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common) // keeps flickering while a menu is open
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        setLit([Bool](repeating: false, count: 8))
    }

    private func tick() {
        guard let counters = readCounters() else {
            stop()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime

        let rxMoved = counters.received != lastRx
        let txMoved = counters.sent != lastTx
        lastRx = counters.received
        lastTx = counters.sent
        if rxMoved { rxLitUntil = now + 0.09 }
        if txMoved { txLitUntil = now + 0.09 }

        // A real RD light flickers with each burst, so skip the odd tick while data keeps coming
        let rd = rxMoved ? Int.random(in: 0..<4) != 0 : now < rxLitUntil
        let sd = txMoved ? Int.random(in: 0..<4) != 0 : now < txLitUntil

        let bps = readEffectiveBps()
        let highSpeed = bps == 0 || bps >= 9600
        setLit([highSpeed, false, true, true, rd, sd, true, true])
    }

    private func setLit(_ value: [Bool]) {
        if value != lit {
            lit = value
        }
    }
}
