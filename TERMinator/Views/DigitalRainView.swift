import SwiftUI
import AppKit

/// Falling columns of half-width katakana and digits, fading toward the top of each column.
/// Shared by the Konami easter egg (animated, below) and the screensaver (a still frame).
/// Mirrors the Windows client's `Controls/DigitalRain.cs`.
///
/// Columns every 16 pt; each column is a vertical string of random glyphs in `#33FF33` faded by a
/// vertical gradient (transparent at the top, opaque at the leading edge), falling from above the top
/// to the bottom over a random 2.5–6.5 s, repeating, starting after a random 0–1.5 s. Every 90 ms a
/// quarter of the columns get one random glyph changed. Hit-test invisible.
///
/// The fall is computed from the elapsed time each frame (`TimelineView(.animation)`) rather than from
/// per-column animations: the glyph churn rewrites a column's text mid-fall, which would fight a
/// SwiftUI animation on the same view.
struct DigitalRainView: View {
    @StateObject private var model = DigitalRainModel()

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSince(model.startedAt)
                ZStack(alignment: .topLeading) {
                    // A transparent ground: without it the ZStack collapses to the columns' size.
                    Color.clear
                    ForEach(model.columns) { column in
                        Text(column.text)
                            .font(.system(size: DigitalRainModel.fontSize, design: .monospaced))
                            .foregroundColor(.accentGreen)
                            .lineSpacing(DigitalRainModel.lineSpacing)
                            .fixedSize()
                            .mask {
                                LinearGradient(colors: [.clear, .white],
                                               startPoint: .top, endPoint: .bottom)
                            }
                            .offset(x: column.x,
                                    y: model.offsetY(for: column, at: elapsed, height: geometry.size.height))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .onAppear { model.build(size: geometry.size) }
            .onChange(of: geometry.size) { newSize in model.build(size: newSize) }
            .onDisappear { model.stop() }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// The columns and the glyph churn. The fall positions are computed, not stored.
final class DigitalRainModel: ObservableObject {
    static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789")
    static let columnWidth: CGFloat = 16
    static let fontSize: CGFloat = 14
    static let rainLineHeight: CGFloat = 17
    /// 14 pt monospaced lays out at roughly 17 pt already, so no extra leading is added. Kept as a
    /// named constant so the line height can be tuned in one place.
    static let lineSpacing: CGFloat = 0

    struct Column: Identifiable {
        let id: Int
        let x: CGFloat
        /// Seconds for one fall.
        let duration: Double
        /// Seconds before this column starts falling.
        let delay: Double
        /// Pixel height of the glyph string.
        let pixelHeight: CGFloat
        var glyphs: [Character]
        var text: String
    }

    @Published private(set) var columns: [Column] = []
    let startedAt = Date()

    private var mutateTimer: Timer?
    private var builtFor: CGSize = .zero

    deinit {
        mutateTimer?.invalidate()
    }

    func build(size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        // Rebuild only on a real size change: SwiftUI reports the same size repeatedly.
        if abs(size.width - builtFor.width) < 1 && abs(size.height - builtFor.height) < 1 { return }
        builtFor = size

        let rows = Int(size.height / Self.rainLineHeight) + 8
        let count = max(1, Int(ceil(size.width / Self.columnWidth)))
        var built: [Column] = []
        built.reserveCapacity(count)
        for index in 0..<count {
            let columnGlyphs = (0..<rows).map { _ in Self.randomGlyph() }
            built.append(Column(id: index,
                                x: CGFloat(index) * Self.columnWidth,
                                duration: 2.5 + Double.random(in: 0...4),
                                delay: Double.random(in: 0...1.5),
                                pixelHeight: CGFloat(rows) * Self.rainLineHeight,
                                glyphs: columnGlyphs,
                                text: Self.joined(columnGlyphs)))
        }
        columns = built
        startChurn()
    }

    func stop() {
        mutateTimer?.invalidate()
        mutateTimer = nil
    }

    /// Where a column sits at `elapsed` seconds: from just above the top to the bottom edge, looping.
    func offsetY(for column: Column, at elapsed: Double, height: CGFloat) -> CGFloat {
        let live = elapsed - column.delay
        guard live > 0 else { return -column.pixelHeight }
        let progress = (live / column.duration).truncatingRemainder(dividingBy: 1)
        return -column.pixelHeight + CGFloat(progress) * (height + column.pixelHeight)
    }

    private func startChurn() {
        guard mutateTimer == nil else { return }
        let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
            self?.churn()
        }
        RunLoop.main.add(timer, forMode: .common)
        mutateTimer = timer
    }

    /// Every 90 ms a quarter of the columns get one random glyph changed. The whole tick is applied in
    /// one assignment: mutating `columns` in place would publish once per changed column.
    private func churn() {
        guard !columns.isEmpty else { return }
        var updated = columns
        for _ in 0..<max(1, updated.count / 4) {
            let index = Int.random(in: 0..<updated.count)
            guard !updated[index].glyphs.isEmpty else { continue }
            let row = Int.random(in: 0..<updated[index].glyphs.count)
            updated[index].glyphs[row] = Self.randomGlyph()
            updated[index].text = Self.joined(updated[index].glyphs)
        }
        columns = updated
    }

    static func randomGlyph() -> Character {
        glyphs.randomElement() ?? "0"
    }

    /// One glyph per line, which is what makes a column a vertical string.
    static func joined(_ glyphs: [Character]) -> String {
        glyphs.map { String($0) }.joined(separator: "\n")
    }

    // MARK: - Still frame (the screensaver's background)

    /// One still frame of the rain, for a background that shouldn't cost anything per frame (the
    /// screensaver scrolls two stacked copies of it downward). Columns get random lengths and
    /// positions, each fading toward its top like the animated version, and every column is also
    /// drawn one screen-height above and below so the image **tiles vertically** without a seam.
    static func renderStillFrame(size: CGSize) -> NSImage {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let green = NSColor(red: 0.2, green: 1.0, blue: 0.2, alpha: 1.0)

        // The columns are rolled up front, not inside the drawing handler. Windows renders the still
        // to a frozen bitmap; an NSImage drawing handler can be re-invoked (per scale, and per draw
        // for a custom representation), and every column is drawn three times so the image tiles, so
        // rolling inside would give the three copies — and successive draws — different glyphs.
        let columnCount = max(1, Int(ceil(width / columnWidth)))
        let maxLength = max(7, Int(height / rainLineHeight) + 4)
        let stills: [(x: CGFloat, top: CGFloat, glyphs: [Character])] = (0..<columnCount).map { index in
            let length = Int.random(in: 6..<maxLength)
            let columnPixels = CGFloat(length) * rainLineHeight
            return (x: CGFloat(index) * columnWidth,
                    top: CGFloat.random(in: 0...1) * (height + columnPixels * 0.5) - columnPixels,
                    glyphs: (0..<length).map { _ in randomGlyph() })
        }

        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            for column in stills {
                // Drawn a screen above and below too, so the bitmap tiles vertically without a seam.
                for shift in [-height, 0, height] {
                    for (row, glyph) in column.glyphs.enumerated() {
                        // Transparent at the top of the column, opaque at its leading edge.
                        let alpha = CGFloat(row + 1) / CGFloat(column.glyphs.count)
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: green.withAlphaComponent(alpha),
                        ]
                        NSAttributedString(string: String(glyph), attributes: attributes)
                            .draw(at: NSPoint(x: column.x,
                                              y: column.top + shift + CGFloat(row) * rainLineHeight))
                    }
                }
            }
            return true
        }
    }
}
