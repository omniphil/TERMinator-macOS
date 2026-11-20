import SwiftUI

/// A vertically scrolling ticker showing computing history facts.
/// Matches the Android/iOS HistoryTickerView with smooth vertical scrolling and crossfade.
///
/// Since the 1.1.0 layout overhaul the whole ticker area is clickable and opens the full
/// facts list (`onOpenFacts`) instead of advancing; hovering shows a rounded amber outline,
/// a faint amber tint and brighter text, with a "Click to see the full list" tooltip.
struct HistoryTickerView: View {
    /// Called when the ticker is clicked (HomeView opens the facts overlay).
    var onOpenFacts: (() -> Void)? = nil
    var facts: [String] = HistoryFacts.all
    var textColor: Color = .tickerGreen
    var hoverTextColor: Color = .tickerGreenBright
    var backgroundColor: Color = .clear
    var displayDuration: TimeInterval = 8.0
    var transitionDuration: TimeInterval = 1.0
    /// Windows `HistoryTicker.ScrollToNext`: the old line slides up a full ticker height while
    /// fading out, the new one slides up from a full height below, fully opaque (the clip hides
    /// it until it enters). Linear, 1 s.
    private let slideDistance: CGFloat = 48

    @State private var shuffledIndices: [Int] = []
    @State private var currentPosition: Int = 0
    /// The two lines on screen, held as TEXT like Windows' CurrentText / NextText TextBlocks. They used
    /// to be derived from `shuffledIndices[currentPosition]`, so the reshuffle at the end of a cycle
    /// (which happens as a slide starts) swapped the outgoing line mid-slide. Now a line only changes
    /// at a slide boundary.
    @State private var currentText: String = ""
    @State private var nextText: String = ""
    @State private var currentOpacity: Double = 1.0
    @State private var nextOpacity: Double = 0.0
    @State private var currentOffset: CGFloat = 0
    @State private var nextOffset: CGFloat = 48
    @State private var timer: Timer?
    @State private var isAnimating: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        ZStack {
            backgroundColor

            ZStack {
                factText(currentText)
                    .opacity(currentOpacity)
                    .offset(y: currentOffset)

                factText(nextText)
                    .opacity(nextOpacity)
                    .offset(y: nextOffset)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .frame(height: 48)
        .clipped()
        // Hover frame: the same amber cue as the clickable tiles. The fill also makes the
        // gaps between lines clickable, not just the glyphs.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.amberAccent.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isHovered ? Color.amberAccent.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenFacts?()
        }
        .onHover { hovering in
            guard hovering != isHovered else { return }   // exactly one pop per push
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .retroTooltip("Click to see the full list")
        .onAppear {
            startTicker()
        }
        .onDisappear {
            stopTicker()
            // Leaving the home screen while the pointer is on the ticker sends no exit event,
            // which would leave the hand cursor stuck.
            if isHovered {
                isHovered = false
                NSCursor.pop()
            }
        }
    }

    private func fact(at position: Int) -> String {
        guard position >= 0, position < shuffledIndices.count else { return "" }
        return facts[safe: shuffledIndices[position]] ?? ""
    }

    private func factText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(isHovered ? hoverTextColor : textColor)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    private func startTicker() {
        guard !facts.isEmpty else { return }
        shuffleIndices()
        currentPosition = 0
        currentText = fact(at: 0)
        nextText = ""
        currentOpacity = 1
        currentOffset = 0
        nextOpacity = 0
        nextOffset = slideDistance
        guard facts.count > 1 else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: displayDuration, repeats: true) { _ in
            transitionToNext()
        }
    }

    private func stopTicker() {
        timer?.invalidate()
        timer = nil
    }

    private func shuffleIndices() {
        shuffledIndices = Array(0..<facts.count).shuffled()
    }

    private func transitionToNext() {
        guard !isAnimating else { return }
        isAnimating = true

        // Windows ScrollToNext: advance, reshuffling after the last fact, and load the incoming line
        // BEFORE the slide. The outgoing line is already fixed in `currentText`.
        var nextPosition = currentPosition + 1
        if nextPosition >= shuffledIndices.count {
            shuffleIndices()
            nextPosition = 0
        }
        currentPosition = nextPosition

        // Start positions (no animation): next line opaque, a full height below.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            nextText = fact(at: nextPosition)
            nextOpacity = 1
            nextOffset = slideDistance
        }

        withAnimation(.linear(duration: transitionDuration)) {
            currentOpacity = 0
            currentOffset = -slideDistance
            nextOffset = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration) {
            // Swap without animation, as Windows' Completed handler does: the incoming line becomes
            // the current one exactly where it already sits.
            var settle = Transaction()
            settle.disablesAnimations = true
            withTransaction(settle) {
                currentText = nextText
                currentOpacity = 1
                currentOffset = 0
                nextOpacity = 0
                nextOffset = slideDistance
            }
            isAnimating = false
        }
    }
}

// MARK: - Computing History Facts

struct HistoryFacts {
    static let all: [String] = [
        "1945: ENIAC, the first general-purpose electronic computer, is completed",
        "1947: The transistor is invented at Bell Labs",
        "1958: Jack Kilby demonstrates the first integrated circuit",
        "1964: BASIC programming language is created at Dartmouth",
        "1965: Gordon Moore predicts transistor doubling every two years",
        "1968: Douglas Engelbart demos the mouse, hypertext, and video conferencing",
        "1969: ARPANET sends its first message from UCLA to Stanford",
        "1970: UNIX is created at Bell Labs",
        "1971: Intel releases the 4004, the first commercial microprocessor",
        "1972: The C programming language is developed at Bell Labs",
        "1973: Xerox Alto becomes the first computer with a graphical user interface",
        "1974: Vint Cerf and Bob Kahn develop the TCP/IP protocol",
        "1975: The Altair 8800 launches the personal computer revolution",
        "1976: Steve Wozniak builds the Apple I in a garage",
        "1977: The Apple II, TRS-80, and Commodore PET debut",
        "1978: The first BBS goes online in Chicago",
        "1979: VisiCalc launches, the killer app that sold Apple IIs",
        "1981: IBM PC released with 16KB RAM and no hard drive",
        "1981: The Osborne 1 becomes the first portable computer",
        "1982: The Commodore 64 launches, selling 17 million units",
        "1982: Time magazine names the computer \"Machine of the Year\"",
        "1983: TCP/IP becomes the standard protocol for ARPANET",
        "1984: Apple Macintosh debuts with legendary Super Bowl ad",
        "1985: Commodore Amiga 1000 brings multimedia to home computing",
        "1986: Intel releases the 386 processor at 16 MHz",
        "1987: The Amiga 500 becomes the best-selling Amiga ever",
        "1987: IBM PS/2 introduces the VGA graphics standard",
        "1987: GIF image format is introduced by CompuServe",
        "1988: MS-DOS 4.0 adds support for hard drives over 32MB",
        "1990: The World Wide Web goes live on Christmas Day",
        "1991: Linus Torvalds releases the first Linux kernel",
        "1993: Mosaic browser brings the web to the masses",
        "FidoNet at its peak connects over 35,000 BBS systems",
        "A 1200 baud modem could transfer 1MB in about 2 hours",
        "The C64 had more computing power than the Apollo 11",
        "The Amiga could display 4,096 colors when PCs had 16",
        "Early hard drives cost about $100,000 per gigabyte",
        "ANSI art became the dominant art form on BBS systems",
        "The sound of a modem connecting was music to our ears",
        "Door games like Legend of the Red Dragon defined BBS gaming",
        "SysOps were the unsung heroes of the early online world",
        "CBBS, the first BBS, was created by Ward Christensen in 1978",
        "TradeWars 2002 was one of the most popular BBS door games",
        "The XMODEM protocol revolutionized file transfers on BBSes",
        "ZMODEM became the gold standard for BBS file transfers",
        "FidoNet used store-and-forward to relay mail between BBSes",
        "The term \"shareware\" was coined in the BBS era",
        "BBSes pioneered online communities before the internet",
        "The \"elite\" BBS scene used leet speak long before the internet",
        "Calling long distance to reach a BBS could cost a fortune",
        "BBS door games ran as external programs launched by the BBS",
        "File ratios required uploading to earn download credits",
        "ANSI bombs could crash terminals with malicious escape codes",
        "The demoscene grew from the BBS warez scene",
        "QWK packets let users read BBS messages offline",
        "Blueboxing and phreaking were closely tied to BBS culture",
        "Many BBSes had only one phone line - busy signals were common",
        "14.4k modems were blazing fast in the early 90s",
        "28.8k and 56k modems arrived just as BBSes began to fade",
        "Echomail let BBSes share message forums across FidoNet",
        "NetMail was FidoNet's version of email between systems",
        "Many SysOps ran BBSes from their bedrooms as teenagers",
        "Some BBSes are still running today on Telnet",
        "1979: Hayes introduces the Smartmodem with AT commands",
        "1980: Usenet launches, connecting universities via UUCP",
        "1983: CompuServe introduces CB Simulator, early chat rooms",
        "1984: FidoNet is created by Tom Jennings in San Francisco",
        "1985: Quantum Link launches, later becoming AOL",
        "1986: LISTSERV creates the first email mailing lists",
        "1988: IRC (Internet Relay Chat) is created in Finland",
        "The Hayes AT command set became the industry standard",
        "2400 baud modems made real-time chat practical on BBSes",
        "V.32bis modems brought 14.4 kbps speeds in 1991",
        "V.34 modems reached 28.8 kbps, then 33.6 kbps",
        "V.90 and V.92 achieved 56 kbps - the analog limit",
        "Prodigy, CompuServe, and GEnie were early online services",
        "The Source was one of the first consumer online services",
        "Synchronet BBS software is still actively developed today",
        "Mystic BBS keeps the BBS tradition alive on modern systems",
        "The FOSSIL driver standardized serial port access for BBSes",
        "YMODEM added batch file transfers to XMODEM",
        "Kermit protocol was popular on mainframes and minicomputers",
        "BiModem allowed simultaneous chat and file transfers",
        "HSLink could transfer files in both directions at once",
        "The Telnet protocol gave BBSes new life on the internet",
        "SSH connections now secure modern BBS communications",
        "SyncTERM keeps classic terminal emulation alive today",
        "Zone 1 was North America in FidoNet addressing",
        "A FidoNet address looked like 1:123/456.7",
        "Points were users who picked up mail from a BBS node",
    ]
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
