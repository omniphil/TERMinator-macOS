import Foundation

/// One message of Rainwire's window protocol (Rainwire docs/WINDOWS.md, protocol v1). Every message is one APC string:
///   ESC _ Rainwire:WM;<Verb>[;key=value]... ESC \
/// Verbs are 1-16 ASCII letters, keys 1-16 of a-z, 0-9 and _. In values, '%', ';', '=', the C0 controls, DEL and the
/// C1 controls (U+0080-U+009F) are written as %XX; everything else is UTF-8 as it is. Window data travels as b64=.
/// The native bridge (Bridge/apc/wm_bridge.c) strips "Rainwire:WM;" before queueing a message for us.
/// Port of the Windows client's `RainwireWm/WmMessage.cs`; no AppKit in here.
final class WmMessage: CustomStringConvertible {
    static let prefix = "Rainwire:WM;"
    static let version = 1
    /// The most window data one Data or Input message carries before base64.
    static let maxData = 2048
    /// A message from the board longer than this is refused (a full Data message is about 2.8 KB).
    static let maxLen = 8000
    static let maxArgs = 32

    let verb: String
    var args: [(key: String, value: String)] = []

    /// A message; kv is key, value, key, value...
    init(_ verb: String, _ kv: String...) {
        self.verb = verb
        var i = 0
        while i + 1 < kv.count {
            args.append((kv[i], kv[i + 1]))
            i += 2
        }
    }

    /// An argument's value, or "" when it isn't there.
    func get(_ key: String) -> String {
        for a in args where a.key == key {
            return a.value
        }
        return ""
    }

    /// An argument as a number from -99999 to 99999, as the protocol allows.
    func int(_ key: String) -> Int? {
        let s = Array(get(key).utf8)
        if s.isEmpty || s.count > 6 {
            return nil
        }
        var i = 0, sign = 1, n = 0
        if s[0] == UInt8(ascii: "-") || s[0] == UInt8(ascii: "+") {
            sign = s[0] == UInt8(ascii: "-") ? -1 : 1
            i = 1
        }
        if i == s.count {
            return nil
        }
        while i < s.count {
            guard s[i] >= UInt8(ascii: "0"), s[i] <= UInt8(ascii: "9") else { return nil }
            n = n * 10 + Int(s[i] - UInt8(ascii: "0"))
            i += 1
        }
        n *= sign
        return n < -99999 || n > 99999 ? nil : n
    }

    /// The b64= argument decoded, or nil if it is missing or not valid base64.
    func data() -> [UInt8]? {
        guard let d = Data(base64Encoded: get("b64")) else { return nil }
        return [UInt8](d)
    }

    /// The message as it goes on the wire, APC and all.
    func encode() -> [UInt8] {
        var b: [UInt8] = [0x1B, UInt8(ascii: "_")]
        b.append(contentsOf: Array((WmMessage.prefix + verb).utf8))
        for a in args {
            b.append(UInt8(ascii: ";"))
            b.append(contentsOf: Array(a.key.utf8))
            b.append(UInt8(ascii: "="))
            WmMessage.escape(&b, a.value)
        }
        b.append(0x1B)
        b.append(UInt8(ascii: "\\"))
        return b
    }

    /// Splits input (or output) into Input (or Data) messages of at most maxData bytes each.
    static func dataMessages(_ verb: String, _ id: Int, _ data: [UInt8]) -> [WmMessage] {
        var list: [WmMessage] = []
        var at = 0
        while at < data.count {
            let n = min(data.count - at, maxData)
            list.append(WmMessage(verb, "id", String(id), "b64", Data(data[at..<(at + n)]).base64EncodedString()))
            at += n
        }
        return list
    }

    private static func escape(_ b: inout [UInt8], _ value: String) {
        let s = Array(value.utf8)
        var i = 0
        while i < s.count {
            let c = s[i]
            // A C1 control is C2 80..C2 9F in UTF-8: both bytes are escaped, never sent raw inside an APC
            let c1 = c == 0xC2 && i + 1 < s.count && s[i + 1] >= 0x80 && s[i + 1] <= 0x9F
            if c == UInt8(ascii: "%") || c == UInt8(ascii: ";") || c == UInt8(ascii: "=") || c < 0x20 || c == 0x7F || c1 {
                hex(&b, c)
                if c1 {
                    i += 1
                    hex(&b, s[i])
                }
            } else {
                b.append(c)
            }
            i += 1
        }
    }

    private static func hex(_ b: inout [UInt8], _ c: UInt8) {
        let digits = Array("0123456789abcdef".utf8)
        b.append(UInt8(ascii: "%"))
        b.append(digits[Int(c >> 4)])
        b.append(digits[Int(c & 15)])
    }

    /// Reads a message: its APC body with or without the "Rainwire:WM;" prefix (the native bridge strips it).
    /// Returns nil for anything malformed, which is then ignored.
    static func parse(_ input: [UInt8]) -> WmMessage? {
        var body = input[...]
        let pre = Array(prefix.utf8)
        if body.starts(with: pre) {
            body = body.dropFirst(pre.count)
        }
        if body.isEmpty || body.count > maxLen {
            return nil
        }

        let semiIndex = body.firstIndex(of: UInt8(ascii: ";"))
        let verbBytes = semiIndex.map { body[body.startIndex..<$0] } ?? body
        guard validVerb(verbBytes) else { return nil }
        let msg = WmMessage(String(decoding: verbBytes, as: UTF8.self))
        guard let first = semiIndex else { return msg }
        var rest = body[(first + 1)...]
        if rest.isEmpty {
            return nil   // "Verb;" with nothing after it
        }

        while true {
            let semi = rest.firstIndex(of: UInt8(ascii: ";"))
            let part = semi.map { rest[rest.startIndex..<$0] } ?? rest
            guard let eq = part.firstIndex(of: UInt8(ascii: "=")) else { return nil }
            let key = part[part.startIndex..<eq]
            guard validKey(key), msg.args.count < maxArgs,
                  let value = unescape(part[(eq + 1)...]) else { return nil }
            msg.args.append((String(decoding: key, as: UTF8.self), value))
            guard let s = semi else { break }
            rest = rest[(s + 1)...]
        }
        return msg
    }

    static func parse(_ body: String) -> WmMessage? {
        parse(Array(body.utf8))
    }

    private static func unescape(_ v: ArraySlice<UInt8>) -> String? {
        if !v.contains(UInt8(ascii: "%")) {
            return String(decoding: v, as: UTF8.self)
        }
        let a = Array(v)
        var b: [UInt8] = []
        b.reserveCapacity(a.count)
        var i = 0
        while i < a.count {
            if a[i] != UInt8(ascii: "%") {
                b.append(a[i])
                i += 1
                continue
            }
            if i + 2 >= a.count {
                return nil   // a '%' without two hex digits after it
            }
            let hi = hexValue(a[i + 1]), lo = hexValue(a[i + 2])
            if hi < 0 || lo < 0 {
                return nil
            }
            b.append(UInt8(hi << 4 | lo))
            i += 3
        }
        return String(decoding: b, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> Int {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(c - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(c - UInt8(ascii: "A")) + 10
        default: return -1
        }
    }

    private static func validVerb(_ s: ArraySlice<UInt8>) -> Bool {
        if s.isEmpty || s.count > 16 {
            return false
        }
        return s.allSatisfy { ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) }
    }

    private static func validKey(_ s: ArraySlice<UInt8>) -> Bool {
        if s.isEmpty || s.count > 16 {
            return false
        }
        return s.allSatisfy {
            ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || $0 == UInt8(ascii: "_")
        }
    }

    var description: String {
        var s = verb
        for a in args {
            s += ";\(a.key)=" + (a.key == "b64" ? "<\(a.value.count) b64>" : a.value)
        }
        return s
    }
}
