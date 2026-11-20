import SwiftUI

/// HUD "target lock" laid over a Quick Connect snapshot (spec §5). When the pointer enters the tile,
/// four green corner brackets snap in around the image and the connection target decrypts across a
/// caption strip along the bottom. Mirrors the Windows client's `Controls/TargetLockOverlay.cs`.
///
/// Hit-test invisible, so clicks still reach the tile button underneath. An empty `target` (an empty
/// Quick Connect slot) shows nothing.
struct TargetLockOverlay: View {
    /// Caption text, e.g. "TELNET // absinthebbs.net:1940".
    let target: String
    /// True while the pointer is inside the tile.
    let locked: Bool

    private static let bracketSize: CGFloat = 14
    private static let bracketInset: CGFloat = 3
    private static let stroke: CGFloat = 2

    @State private var opacity: Double = 0
    @State private var snap: CGFloat = 1.22
    @State private var captionTrigger: Int = 0

    var body: some View {
        ZStack {
            // Caption strip along the bottom of the snapshot, brackets on top of it.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                DecryptText(text: target, duration: 0.42, replayTrigger: captionTrigger)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.accentGreen)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.8))
            }
            .padding(EdgeInsets(top: 0, leading: 3, bottom: 3, trailing: 3))

            brackets
                .scaleEffect(snap)
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .onChange(of: locked) { isLocked in
            if isLocked {
                guard !target.isEmpty else { return }
                captionTrigger += 1
                // Put the brackets back at 1.22x unanimated, then snap them in on the next turn of
                // the main loop. Both writes in one update coalesce — SwiftUI would only ever see the
                // final 1x, and every hover after the first would show no snap at all.
                withTransaction(Transaction(animation: nil)) { snap = 1.22 }
                withAnimation(.linear(duration: 0.11)) { opacity = 1 }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.17)) { self.snap = 1 }
                }
            } else {
                withAnimation(.linear(duration: 0.14)) { opacity = 0 }
            }
        }
    }

    /// Four 14×14 L-shapes, 3 pt in from each corner, 2 pt strokes with a green glow (blur 6).
    private var brackets: some View {
        ZStack {
            bracket(.topLeading)
            bracket(.topTrailing)
            bracket(.bottomLeading)
            bracket(.bottomTrailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: Color.accentGreen.opacity(0.9), radius: 3)
    }

    private enum BracketCorner {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: return .topLeading
            case .topTrailing: return .topTrailing
            case .bottomLeading: return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }
    }

    private func bracket(_ corner: BracketCorner) -> some View {
        let size = Self.bracketSize
        var path = Path()
        switch corner {
        case .topLeading:
            path.move(to: CGPoint(x: 0, y: size))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size, y: 0))
        case .topTrailing:
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size, y: 0))
            path.addLine(to: CGPoint(x: size, y: size))
        case .bottomLeading:
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: size))
            path.addLine(to: CGPoint(x: size, y: size))
        case .bottomTrailing:
            path.move(to: CGPoint(x: size, y: 0))
            path.addLine(to: CGPoint(x: size, y: size))
            path.addLine(to: CGPoint(x: 0, y: size))
        }
        return path
            .stroke(Color.accentGreen, lineWidth: Self.stroke)
            .frame(width: size, height: size)
            .padding(Self.bracketInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
    }
}
