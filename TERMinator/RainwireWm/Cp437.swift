import Foundation

/// Code page 437, both ways. A Rainwire window's screen comes in the character set the board detected for this
/// terminal, which for TERMinator's SyncTERM core is CP437, so window cells hold CP437 codes and draw with the same
/// bitmap font as the main screen. This is for turning them into text (drag labels) and typed text into bytes.
/// Port of the Windows client's `RainwireWm/Cp437.cs`.
enum Cp437 {
    private static let table: [Character] = Array(
        "\u{0000}☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼" +
        " !\"#$%&'()*+,-./0123456789:;<=>?" +
        "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_" +
        "`abcdefghijklmnopqrstuvwxyz{|}~⌂" +
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒ" +
        "áíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐" +
        "└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀" +
        "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}")

    private static let reverse: [Character: UInt8] = {
        var d: [Character: UInt8] = [:]
        for (i, c) in table.enumerated() where d[c] == nil {
            d[c] = UInt8(i)
        }
        return d
    }()

    /// The character a CP437 code shows.
    static func toChar(_ code: UInt8) -> Character {
        table.count == 256 ? table[Int(code)] : "?"
    }

    /// A typed character as the byte to send, or nil if CP437 has no such character.
    static func fromChar(_ c: Character) -> UInt8? {
        if let a = c.asciiValue, a >= 0x20, a < 0x7F {
            return a
        }
        if let b = reverse[c], b >= 0x80 {
            return b
        }
        return nil
    }
}
