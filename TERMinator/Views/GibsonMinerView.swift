import SwiftUI

/// Screensaver prop (spec §8): a completely fake GibsonCoin miner console that looks busy — a
/// jittery hash rate, a share progress bar, scrolling nonce / share log lines, GPU stats, a
/// creeping balance and the occasional BLOCK FOUND with a flashing border. Mirrors the Windows
/// client's `Controls/GibsonMinerPanel.cs`; the screensaver drives `tick` every frame and hops the
/// whole box around on its own clock. The stats only change once a second, like a real miner's
/// console, so the text isn't re-laid-out every frame.
final class GibsonMinerModel: ObservableObject {
    /// The log keeps the last five lines.
    static let logLines = 5
    static let logLineHeight: CGFloat = 13
    private static let blockReward = 6.25
    private static let textUpdateInterval: Double = 1

    struct LogLine: Identifiable {
        let id: Int
        let text: String
        let color: Color
    }

    @Published private(set) var hashText: String = ""
    @Published private(set) var hardwareText: String = ""
    @Published private(set) var balanceText: String = ""
    /// 0–1, the share bar's fill.
    @Published private(set) var progress: Double = 0
    @Published private(set) var log: [LogLine] = []
    /// The border flashes white/gold at 12 Hz for 0.7 s after a block.
    @Published private(set) var borderWhite = false

    private var nextTextUpdate: Double = 0
    private var balanceValue: Double
    private var nextBlockTime: Double
    private var flashUntil: Double = 0
    private var blockHeight: Int
    private var accepted = 0
    private var submitted = 0
    private var nextLogId = 0

    init() {
        balanceValue = 12.48213377 + Double.random(in: 0..<1) * 3
        blockHeight = 482113 + Int.random(in: 0..<5000)
        nextBlockTime = 6 + Double.random(in: 0..<1) * 6
        addLog("connecting to pool... authorized", Self.successColor)
        balanceText = Self.balanceLine(balanceValue)
    }

    /// Advances the fake mining. `t` is seconds since the screensaver started.
    func tick(t: Double, dt: Double) {
        // The share bar fills up; each full bar submits a share (the odd one gets rejected).
        progress += dt * (0.35 + Double.random(in: 0..<1) * 0.3)
        if progress >= 1 {
            progress = 0
            submitted += 1
            let wasAccepted = Double.random(in: 0..<1) > 0.08
            if wasAccepted { accepted += 1 }
            addLog(wasAccepted ? "\u{2714} share accepted (\(accepted)/\(submitted))"
                               : "\u{2718} share rejected (\(accepted)/\(submitted))",
                   wasAccepted ? Self.successColor : Self.errorColor)
        }

        balanceValue += dt * 0.00042

        // Now and then: a block!
        if t >= nextBlockTime {
            blockHeight += 1
            balanceValue += Self.blockReward
            addLog("*** BLOCK #\(Self.grouped(blockHeight)) FOUND! +6.25 GBC ***", Self.goldColor)
            flashUntil = t + 0.7
            nextBlockTime = t + 12 + Double.random(in: 0..<1) * 8
        }
        let white = t < flashUntil && Int(t * 12) % 2 == 0
        if white != borderWhite {
            borderWhite = white
        }

        // The stats refresh once a second.
        guard t >= nextTextUpdate else { return }
        nextTextUpdate = t + Self.textUpdateInterval

        let rate = 1337 + sin(t * 0.7) * 120 + Double.random(in: 0..<1) * 40
        hashText = "HASH  \(Self.grouped(rate, decimals: 2)) GH/s"
        hardwareText = "GPU0 \(84 + Int.random(in: 0..<5))\u{00B0}C  FAN 100%  PWR \(410 + Int.random(in: 0..<25))W"
        balanceText = Self.balanceLine(balanceValue)
        if Double.random(in: 0..<1) < 0.8 {
            addLog("nonce 0x\(Self.randomHex(8, uppercase: true))  hash 0000\(Self.randomHex(12))",
                   Self.dimColor)
        }
    }

    private func addLog(_ text: String, _ color: Color) {
        log.append(LogLine(id: nextLogId, text: text, color: color))
        nextLogId += 1
        if log.count > Self.logLines {
            log.removeFirst(log.count - Self.logLines)
        }
    }

    // MARK: - Formatting

    private static func balanceLine(_ value: Double) -> String {
        "BALANCE  " + String(format: "%.8f", value) + " GBC"
    }

    /// .NET's "N0" / "N2": grouped thousands, invariant culture.
    private static func grouped(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
    }

    private static func grouped(_ value: Int) -> String {
        grouped(Double(value), decimals: 0)
    }

    private static func randomHex(_ length: Int, uppercase: Bool = false) -> String {
        let digits = Array(uppercase ? "0123456789ABCDEF" : "0123456789abcdef")
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            out.append(digits[Int.random(in: 0..<digits.count)])
        }
        return out
    }

    // MARK: - Palette (exactly the Windows panel's)

    static let goldColor = Color(red: 1.0, green: 0.843, blue: 0.0)            // #FFD700
    static let successColor = Color(red: 0.2, green: 1.0, blue: 0.2)           // #33FF33
    static let errorColor = Color(red: 1.0, green: 0.333, blue: 0.333)         // #FF5555
    static let dimColor = Color(red: 0.478, green: 0.478, blue: 0.549)         // #7A7A8C
    static let greenColor = Color(red: 0.333, green: 0.867, blue: 0.333)       // #55DD55
    static let amberColor = Color(red: 1.0, green: 0.667, blue: 0.0)           // #FFAA00
}

/// The miner box itself. A fixed 310 × 212 so the screensaver can place it without measuring:
/// every row carries an explicit height, exactly as the Windows panel's stack adds up.
struct GibsonMinerView: View {
    @ObservedObject var model: GibsonMinerModel

    static let boxSize = CGSize(width: 310, height: 212)
    private static let border: CGFloat = 1.5
    private static let paddingH: CGFloat = 12
    private static let paddingV: CGFloat = 10
    /// 310 − both borders − both paddings.
    private static let contentWidth = boxSize.width - 2 * border - 2 * paddingH

    private static let coinFill = RadialGradient(
        colors: [Color(red: 1.0, green: 0.953, blue: 0.627),   // #FFF3A0
                 Color(red: 0.784, green: 0.573, blue: 0.0)],  // #C89200
        center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 15)
    private static let coinStroke = Color(red: 0.541, green: 0.384, blue: 0.0)   // #8A6200
    private static let coinLetter = Color(red: 0.416, green: 0.282, blue: 0.0)   // #6A4800
    private static let boxFill = Color(red: 0.024, green: 0.024, blue: 0.063)    // #060610
    private static let barTrack = Color(red: 0.063, green: 0.063, blue: 0.125)   // #101020
    private static let barBorder = Color(red: 0.165, green: 0.165, blue: 0.290)  // #2A2A4A
    private static let barFill = LinearGradient(
        colors: [Color(red: 0.333, green: 1.0, blue: 1.0),      // #55FFFF
                 Color(red: 0.133, green: 0.533, blue: 1.0)],   // #2288FF
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(width: Self.contentWidth, height: 24)
                .padding(.bottom, 6)

            line("rig GIBSON-01  pool stratum+tcp://gibson.pool:1337", 10, GibsonMinerModel.dimColor)
                .frame(height: 13)

            line(model.hashText, 13, GibsonMinerModel.greenColor, bold: true)
                .frame(height: 17)
                .padding(.top, 6)
                .padding(.bottom, 4)

            progressBar
                .frame(width: Self.contentWidth, height: 8)

            logView
                .frame(width: Self.contentWidth,
                       height: GibsonMinerModel.logLineHeight * CGFloat(GibsonMinerModel.logLines),
                       alignment: .top)
                .clipped()
                .padding(.vertical, 6)

            line(model.hardwareText, 10, GibsonMinerModel.amberColor)
                .frame(height: 13)

            line(model.balanceText, 13, GibsonMinerModel.goldColor, bold: true)
                .frame(height: 17)
                .padding(.top, 4)
        }
        .frame(width: Self.contentWidth, alignment: .leading)
        .padding(.horizontal, Self.paddingH)
        .padding(.vertical, Self.paddingV)
        // The box is 310 wide *including* its border and padding, as WPF's `Border.Width` is, so the
        // frame comes before the fill and the border: both then cover the full 310 × 212.
        .frame(width: Self.boxSize.width, height: Self.boxSize.height)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Self.boxFill.opacity(0.93))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(model.borderWhite ? Color.white : GibsonMinerModel.goldColor,
                              lineWidth: Self.border)
        )
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ZStack {
                Circle().fill(Self.coinFill)
                Circle().strokeBorder(Self.coinStroke, lineWidth: 1.5)
                Text("G")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Self.coinLetter)
            }
            .frame(width: 24, height: 24)
            .padding(.trailing, 8)

            line("GIBSONCOIN MINER", 14, GibsonMinerModel.goldColor, bold: true)
        }
    }

    private var progressBar: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Self.barTrack)
            // Scaled rather than resized, so the fill moving every frame never re-lays-out the row
            Rectangle()
                .fill(Self.barFill)
                .frame(width: Self.contentWidth - 2)
                .scaleEffect(x: CGFloat(model.progress), y: 1, anchor: .leading)
                .padding(.leading, 1)
        }
        .overlay(Rectangle().strokeBorder(Self.barBorder, lineWidth: 1))
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.log) { entry in
                line(entry.text, 10, entry.color)
                    .frame(height: GibsonMinerModel.logLineHeight)
            }
        }
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private func line(_ text: String, _ size: CGFloat, _ color: Color, bold: Bool = false) -> some View {
        Text(text)
            .font(.system(size: size, weight: bold ? .bold : .regular, design: .monospaced))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
