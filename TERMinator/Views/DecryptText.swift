import SwiftUI

/// "Decrypt" text effect: the characters churn through random glyphs and lock in left to right.
/// Mirrors the Windows client's `Controls/DecryptText.cs`.
///
/// Use it in place of `Text` and style it the same way (`.font`, `.foregroundColor`, `.lineLimit`, ...).
/// The effect plays when the value changes and **every time the view appears**, so it replays on every
/// return to the home screen. Pass an incrementing `replayTrigger` to replay it on demand — that is how
/// the Quick Connect names, the shortcut labels and the target-lock caption replay on hover.
///
/// Whitespace stays put, the steps are 30 ms, and the default duration is
/// `clamp(220 + 14 × length, 250, 700)` ms.
struct DecryptText: View {
    let text: String
    /// Seconds. nil = the length-based default.
    var duration: Double? = nil
    /// Any change to this value replays the effect (hover replay).
    var replayTrigger: Int = 0

    @StateObject private var model = DecryptTextModel()

    var body: some View {
        Text(model.display)
            .onAppear { model.play(text, duration: duration) }
            .onDisappear { model.stop(snapTo: text) }
            // One watch on both, playing the value SwiftUI hands over. An `onChange` closure is the
            // one from the previous render, so a separate replayTrigger watch reading `text` played
            // the old string whenever both changed in one update (the screensaver's caption named
            // the previous board every slide).
            .onChange(of: Replay(text: text, trigger: replayTrigger)) { replay in
                model.play(replay.text, duration: duration)
            }
    }

    private struct Replay: Equatable {
        let text: String
        let trigger: Int
    }
}

/// The churning itself, kept in an object so the timer survives SwiftUI's view-struct churn.
/// Deliberately not `@MainActor`: the timer fires on the main run loop and every caller is a view.
final class DecryptTextModel: ObservableObject {
    /// The glyph soup the characters churn through, exactly as on Windows.
    private static let glyphs = Array("!<>-_\\/[]{}=+*^?#%&$@01")

    @Published private(set) var display: String = ""

    private var timer: Timer?

    deinit {
        timer?.invalidate()
    }

    /// Plays the effect, ending on `finalText`.
    func play(_ finalText: String, duration: Double? = nil) {
        timer?.invalidate()
        timer = nil

        let characters = Array(finalText)
        guard !characters.isEmpty else {
            display = finalText
            return
        }

        let total = duration ?? Self.defaultDuration(length: characters.count)
        let started = Date()
        display = Self.scramble(characters, locked: 0)

        // .common run loop mode so the churn keeps going during a window resize / menu tracking.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            let progress = Date().timeIntervalSince(started) / total
            if progress >= 1 {
                timer.invalidate()
                self.timer = nil
                self.display = finalText
                return
            }
            self.display = Self.scramble(characters, locked: Int(progress * Double(characters.count)))
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops a running effect. `snapTo` leaves the final text on screen (the view is going away).
    func stop(snapTo finalText: String?) {
        timer?.invalidate()
        timer = nil
        if let finalText = finalText {
            display = finalText
        }
    }

    static func defaultDuration(length: Int) -> Double {
        min(700, max(250, 220 + Double(length) * 14)) / 1000
    }

    private static func scramble(_ characters: [Character], locked: Int) -> String {
        var out = ""
        out.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            if index < locked || character.isWhitespace {
                out.append(character)
            } else {
                out.append(glyphs.randomElement() ?? character)
            }
        }
        return out
    }
}
