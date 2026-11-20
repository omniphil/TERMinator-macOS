import Foundation
import AppKit
import Compression
import UniformTypeIdentifiers

/// Import and export of the phonebook, in the same shape as Windows
/// `PhonebookImportExportService` (the master) and the Linux client.
///
/// A .zip holds `connections.xml` at its root plus a `snapshots/` folder of PNGs named
/// `<connection id>.png`; a bare .xml is the same document with the snapshots inlined as base64
/// `<snapshot>` tags. Both are accepted on import, so a phonebook moves between the clients.
///
/// The .zip is read and written by `PhonebookZip` below (stored + raw-DEFLATE via Apple's
/// Compression framework) — no ZIP library, and no `/usr/bin/ditto` child process, which under
/// App Sandbox would not reliably inherit the NSOpenPanel/NSSavePanel access to the user's file.
/// Everything is built in memory and written in one go to the URL the save panel returned.
///
/// ⚠️ Passwords are NEVER exported — they live in the macOS Keychain. Do not add them.
/// ⚠️ The font does not interchange: macOS writes a conio font INDEX (`<font>`), Windows a font
/// NAME (`<fontName>`). A Windows `fontName` that matches one of our fonts' names is honoured.
class ImportExportManager {

    static let shared = ImportExportManager()

    private init() {}

    private static let xmlFileName = "connections.xml"
    private static let snapshotFolder = "snapshots"

    // MARK: - UI flows (File menu, Preferences > Backup & Restore and the console all use these)

    /// File > Export Phonebook... — Windows `MainWindow.ExportPhonebook`: a save panel defaulting to
    /// `TERMinator_Export_<yyyyMMdd_HHmmss>.zip` (.xml also allowed), then an "Exported N connections."
    /// or "Export failed" box. `completion` gets the count written (0 = nothing / cancelled).
    func runExportFlow(completion: ((Int) -> Void)? = nil) {
        let entries = BBSEntryStore.shared.entries
        guard !entries.isEmpty else {
            showMessage("Export Phonebook", "There are no saved connections to export.", style: .informational)
            completion?(0)
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let panel = NSSavePanel()
        panel.title = "Export Phonebook"
        panel.allowedContentTypes = [.zip, .xml]
        panel.nameFieldStringValue = "TERMinator_Export_\(formatter.string(from: Date())).zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion?(0)
                return
            }
            do {
                let count = try self.export(to: url)
                self.showMessage("Export Phonebook",
                                 "Exported \(count) connection\(count == 1 ? "" : "s").",
                                 style: .informational)
                completion?(count)
            } catch {
                self.showMessage("Export Phonebook", "Export failed:\n\n\(error.localizedDescription)",
                                 style: .warning)
                completion?(0)
            }
        }
    }

    /// File > Import Phonebook... — Windows `MainWindow.ImportPhonebook`: pick a .zip or .xml, then
    /// the same Yes (replace) / No (merge, the default) / Cancel question, then the result box.
    /// `completion` gets the count imported (0 = nothing / cancelled / failed).
    func runImportFlow(completion: ((Int) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Import Phonebook"
        panel.allowedContentTypes = [.zip, .xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion?(0)
                return
            }

            // Yes = replace everything, No = merge, Cancel = back out. Replace is destructive, so it
            // is never the default button (Windows passes MessageBoxResult.No as the default).
            let ask = NSAlert()
            ask.messageText = "Import Phonebook"
            ask.informativeText = "Replace the current phonebook with the imported one?\n\n" +
                "Yes  - discard the existing connections\n" +
                "No   - merge the imported connections into the current list"
            ask.alertStyle = .informational
            let yesButton = ask.addButton(withTitle: "Yes")
            let noButton = ask.addButton(withTitle: "No")
            ask.addButton(withTitle: "Cancel")          // "Cancel" gets Escape automatically
            yesButton.keyEquivalent = ""
            noButton.keyEquivalent = "\r"
            let choice = ask.runModal()
            guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else {
                completion?(0)
                return
            }
            let replace = choice == .alertFirstButtonReturn

            do {
                let count = try self.importConnections(from: url, replace: replace)
                if count == 0 {
                    self.showMessage("Import Phonebook", "No connections were found in that file.", style: .warning)
                } else {
                    self.showMessage("Import Phonebook",
                                     "Imported \(count) connection\(count == 1 ? "" : "s").",
                                     style: .informational)
                }
                completion?(count)
            } catch {
                self.showMessage("Import Phonebook", "Import failed:\n\n\(error.localizedDescription)",
                                 style: .warning)
                completion?(0)
            }
        }
    }

    private func showMessage(_ title: String, _ text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Export

    /// Write every saved connection to `url`: the archive layout for a .zip, the single-file XML
    /// (snapshots inlined) for anything else. Returns how many connections were written.
    @discardableResult
    func export(to url: URL) throws -> Int {
        let entries = BBSEntryStore.shared.entries
        guard !entries.isEmpty else { return 0 }

        let data: Data
        if url.pathExtension.lowercased() == "zip" {
            var files: [(name: String, data: Data)] = []
            files.append((name: Self.xmlFileName,
                          data: Data(generateXML(from: entries, inlineSnapshots: false).utf8)))
            for entry in entries {
                if let png = entry.snapshotData, !png.isEmpty {
                    files.append((name: "\(Self.snapshotFolder)/\(Self.exportId(entry.id)).png", data: png))
                }
            }
            data = PhonebookZip.build(files)
        } else {
            data = Data(generateXML(from: entries, inlineSnapshots: true).utf8)
        }

        // Built entirely in memory, so one plain write cannot leave a half-built archive behind.
        // Not `.atomic`: that stages a sibling temp file, which the sandbox's user-selected-file
        // grant does not always cover.
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try data.write(to: url)
        return entries.count
    }

    /// Ids go out lowercase, as Windows' `Guid.ToString()` writes them, so a phonebook that
    /// travels Windows -> macOS -> Windows still merges onto the same entries there.
    private static func exportId(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    // MARK: - Import

    /// Read connections from a .zip or .xml and add them to the phonebook. With `replace` the
    /// existing phonebook is cleared first; otherwise any entry whose id already exists is updated
    /// in place and the rest are appended (importing the same file twice does not duplicate).
    /// Like Windows, anything that is not a .zip is read as XML. Returns how many were imported.
    func importConnections(from url: URL, replace: Bool) throws -> Int {
        let data = try Data(contentsOf: url)
        let entries: [BBSEntry]
        if url.pathExtension.lowercased() == "zip" {
            entries = try parseZip(data)
        } else {
            let xml = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            entries = parseXML(xml, snapshots: nil)
        }

        guard !entries.isEmpty else { return 0 }
        BBSEntryStore.shared.importEntries(entries, replace: replace)
        return entries.count
    }

    private func parseZip(_ data: Data) throws -> [BBSEntry] {
        let members = try PhonebookZip.read(data)

        // Old macOS exports zipped the staging FOLDER, so the XML can be "connections.xml" or
        // "<something>/connections.xml": match on the file name, as Windows does.
        let xmlName = Self.xmlFileName
        guard let xmlMember = members.first(where: {
            ($0.name as NSString).lastPathComponent.lowercased() == xmlName
        }) else {
            return []
        }
        let xmlData = try xmlMember.data()
        let xml = String(data: xmlData, encoding: .utf8) ?? String(decoding: xmlData, as: UTF8.self)

        // Snapshot PNGs keyed by lowercase connection id.
        var shots: [String: Data] = [:]
        for member in members {
            let lower = member.name.lowercased()
            guard lower.contains(Self.snapshotFolder + "/"), lower.hasSuffix(".png") else { continue }
            let key = ((lower as NSString).lastPathComponent as NSString).deletingPathExtension
            if let png = try? member.data(), !png.isEmpty {   // skip a corrupt member, keep going
                shots[key] = png
            }
        }
        return parseXML(xml, snapshots: shots)
    }

    // MARK: - XML Generation

    private func generateXML(from entries: [BBSEntry], inlineSnapshots: Bool) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<connections>\n"

        for entry in entries {
            xml += "  <connection>\n"
            xml += "    <id>\(xmlEscape(Self.exportId(entry.id)))</id>\n"
            xml += "    <name>\(xmlEscape(entry.name))</name>\n"
            xml += "    <host>\(xmlEscape(entry.host))</host>\n"
            xml += "    <port>\(entry.port)</port>\n"
            // The native connection type (3 telnet, 4 raw, 5 ssh, 13/14/15) — what Windows writes too.
            xml += "    <protocol>\(entry.connectionProtocol.rawValue)</protocol>\n"
            xml += "    <username>\(xmlEscape(entry.username))</username>\n"
            xml += "    <screenMode>\(entry.screenMode.rawValue)</screenMode>\n"
            xml += "    <font>\(entry.font.rawValue)</font>\n"
            xml += "    <zoomLevel>\(entry.zoomLevel)</zoomLevel>\n"
            xml += "    <showStatusBar>\(entry.showStatusBar)</showStatusBar>\n"
            xml += "    <autoConnect>\(entry.autoConnect)</autoConnect>\n"

            // Passwords are intentionally NOT exported (Keychain only).

            if inlineSnapshots, let snapshotData = entry.snapshotData, !snapshotData.isEmpty {
                xml += "    <snapshot>\(snapshotData.base64EncodedString())</snapshot>\n"
            }

            xml += "  </connection>\n"
        }

        xml += "</connections>\n"
        return xml
    }

    // MARK: - XML Parsing

    private func parseXML(_ xmlContent: String, snapshots: [String: Data]?) -> [BBSEntry] {
        var entries: [BBSEntry] = []

        let connectionPattern = "<connection>(.*?)</connection>"
        guard let connectionRegex = try? NSRegularExpression(pattern: connectionPattern, options: .dotMatchesLineSeparators) else {
            return entries
        }

        let range = NSRange(xmlContent.startIndex..., in: xmlContent)
        let matches = connectionRegex.matches(in: xmlContent, options: [], range: range)

        for match in matches {
            if let connectionRange = Range(match.range(at: 1), in: xmlContent) {
                let connectionXML = String(xmlContent[connectionRange])
                if let entry = parseConnectionXML(connectionXML, snapshots: snapshots) {
                    entries.append(entry)
                }
            }
        }

        return entries
    }

    /// Field rules follow Windows `ParseXml`: no host = skipped; a blank name falls back to the host;
    /// a missing / non-positive port is 23; an unknown protocol is telnet; a missing id gets a new one.
    private func parseConnectionXML(_ xml: String, snapshots: [String: Data]?) -> BBSEntry? {
        func extractValue(_ tag: String) -> String? {
            let pattern = "<\(tag)>(.*?)</\(tag)>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
                return nil
            }
            let range = NSRange(xml.startIndex..., in: xml)
            if let match = regex.firstMatch(in: xml, options: [], range: range),
               let valueRange = Range(match.range(at: 1), in: xml) {
                return xmlUnescape(String(xml[valueRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }

        guard let host = extractValue("host"), !host.isEmpty else {
            return nil
        }
        let rawName = extractValue("name") ?? ""
        let name = rawName.isEmpty ? host : rawName

        let rawId = extractValue("id") ?? ""
        let id = UUID(uuidString: rawId) ?? UUID()

        let parsedPort = Int(extractValue("port") ?? "") ?? 0
        let port = parsedPort > 0 ? parsedPort : 23
        let protocolValue = Int(extractValue("protocol") ?? "") ?? ConnectionProtocol.telnet.rawValue
        let connectionProtocol = ConnectionProtocol(rawValue: protocolValue) ?? .telnet
        let username = extractValue("username") ?? ""
        let screenModeValue = Int(extractValue("screenMode") ?? "") ?? ScreenMode.mode80x25.rawValue
        let screenMode = ScreenMode(rawValue: screenModeValue) ?? .mode80x25

        // <font> is ours (an index; 1 = legacy Topaz Plus); <fontName> is Windows'.
        var font = TerminalFont.cp437
        if let fontValue = Int(extractValue("font") ?? "") {
            font = fontValue == 1 ? .topazPlus : (TerminalFont(rawValue: fontValue) ?? .cp437)
        } else if let fontName = extractValue("fontName"), !fontName.isEmpty,
                  let match = TerminalFont.allCases.first(where: {
                      $0.fontName.caseInsensitiveCompare(fontName) == .orderedSame
                          || $0.displayName.caseInsensitiveCompare(fontName) == .orderedSame
                  }) {
            font = match
        }

        let zoomLevel = Int(extractValue("zoomLevel") ?? "") ?? 100
        // Windows: anything but "true" is false. Legacy macOS files may carry hideStatusLine instead.
        let showStatusBar: Bool
        if let value = extractValue("showStatusBar") {
            showStatusBar = value.lowercased() == "true"
        } else if let value = extractValue("hideStatusLine") {
            showStatusBar = value.lowercased() != "true"
        } else {
            showStatusBar = true
        }
        let autoConnect = extractValue("autoConnect")?.lowercased() == "true"

        // Snapshot: the zip member wins, then an inlined base64 <snapshot>. The picture lands in
        // BBSEntry.snapshotData, which is where the phonebook/home tiles read their thumbnails.
        var snapshotData: Data? = nil
        if let shots = snapshots, !rawId.isEmpty, let png = shots[rawId.lowercased()] {
            snapshotData = png
        } else if let base64String = extractValue("snapshot"), !base64String.isEmpty {
            snapshotData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters)
        }

        return BBSEntry(
            id: id,
            name: name,
            host: host,
            port: port,
            connectionProtocol: connectionProtocol,
            username: username,
            screenMode: screenMode,
            font: font,
            zoomLevel: zoomLevel,
            showStatusBar: showStatusBar,
            autoConnect: autoConnect,
            snapshotData: snapshotData
        )
    }

    // MARK: - XML Escaping

    private func xmlEscape(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func xmlUnescape(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Minimal ZIP reader / writer

/// Just enough PKZIP for the phonebook archive: writes stored or raw-DEFLATE members with a
/// central directory (what .NET's `ZipFile` and every unzip read), and reads stored / DEFLATE
/// members from any ordinary archive — Windows `ZipFile.CreateFromDirectory`, the Linux client,
/// Finder's Compress, or an old macOS export. No ZIP64, no encryption (a phonebook needs neither).
/// DEFLATE is `COMPRESSION_ZLIB`, which Apple documents as raw RFC 1951 — exactly ZIP method 8.
enum PhonebookZip {

    struct Member {
        let name: String
        let method: Int
        let crc: UInt32
        let uncompressedSize: Int
        let payload: Data

        /// The member's bytes, inflated if need be and CRC-checked.
        func data() throws -> Data {
            let out: Data
            switch method {
            case 0:
                out = payload
            case 8:
                if uncompressedSize == 0 { return Data() }
                guard let inflated = PhonebookZip.inflate(payload, expectedSize: uncompressedSize) else {
                    throw PhonebookZip.failure("\(name) could not be decompressed.")
                }
                out = inflated
            default:
                throw PhonebookZip.failure("\(name) uses an unsupported compression method (\(method)).")
            }
            guard PhonebookZip.crc32(out) == crc else {
                throw PhonebookZip.failure("\(name) is damaged (CRC mismatch).")
            }
            return out
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "PhonebookZip", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Read

    static func read(_ data: Data) throws -> [Member] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { u16(o) | (u16(o + 2) << 16) }

        // End of central directory: 22 bytes plus a comment of up to 64K, at the very end.
        guard b.count >= 22 else { throw failure("That file is not a zip archive.") }
        var eocd = -1
        var i = b.count - 22
        let lowest = max(0, b.count - 22 - 65_535)
        while i >= lowest {
            if b[i] == 0x50 && b[i + 1] == 0x4B && b[i + 2] == 0x05 && b[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw failure("That file is not a zip archive.") }

        let count = u16(eocd + 10)
        let cdSize = u32(eocd + 12)
        let cdOffset = u32(eocd + 16)
        guard cdOffset + cdSize <= b.count else {
            throw failure("The zip archive is damaged or uses ZIP64.")
        }

        var members: [Member] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x0201_4B50 else { break }
            let flags = u16(p + 8)
            let method = u16(p + 10)
            let crc = UInt32(truncatingIfNeeded: u32(p + 16))
            let compSize = u32(p + 20)
            let uncompSize = u32(p + 24)
            let nameLen = u16(p + 28)
            let extraLen = u16(p + 30)
            let commentLen = u16(p + 32)
            let localOffset = u32(p + 42)
            guard p + 46 + nameLen <= b.count else { break }
            let nameBytes = Array(b[(p + 46)..<(p + 46 + nameLen)])
            let decoded = String(bytes: nameBytes, encoding: .utf8)
                ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            let name = decoded.replacingOccurrences(of: "\\", with: "/")
            p += 46 + nameLen + extraLen + commentLen

            // Directories, encrypted members and anything that runs off the end are skipped.
            if name.isEmpty || name.hasSuffix("/") || (flags & 1) != 0 { continue }
            guard localOffset + 30 <= b.count, u32(localOffset) == 0x0403_4B50 else { continue }
            let start = localOffset + 30 + u16(localOffset + 26) + u16(localOffset + 28)
            guard start + compSize <= b.count else { continue }

            members.append(Member(name: name, method: method, crc: crc,
                                  uncompressedSize: uncompSize,
                                  payload: Data(b[start..<(start + compSize)])))
        }
        return members
    }

    static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard !input.isEmpty else { return nil }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expectedSize, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == expectedSize ? output : nil
    }

    static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + input.count / 10 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    // MARK: Write

    /// A complete archive of `files` (names use "/" separators). Each member is DEFLATEd when that
    /// makes it smaller, otherwise stored (PNGs usually end up stored).
    static func build(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        let stamp = dosTimestamp(Date())

        func put16(_ d: inout Data, _ v: Int) {
            d.append(UInt8(truncatingIfNeeded: v))
            d.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        func put32(_ d: inout Data, _ v: UInt32) {
            put16(&d, Int(v & 0xFFFF))
            put16(&d, Int(v >> 16))
        }

        for file in files {
            let nameBytes = Data(file.name.utf8)
            let crc = crc32(file.data)
            var method = 0
            var payload = file.data
            if let packed = deflate(file.data), packed.count < file.data.count {
                method = 8
                payload = packed
            }
            let offset = UInt32(truncatingIfNeeded: out.count)
            let packedSize = UInt32(truncatingIfNeeded: payload.count)
            let plainSize = UInt32(truncatingIfNeeded: file.data.count)

            // Local file header
            put32(&out, 0x0403_4B50)
            put16(&out, 20)                 // version needed: 2.0
            put16(&out, 0x0800)             // flags: names are UTF-8
            put16(&out, method)
            put16(&out, stamp.time)
            put16(&out, stamp.date)
            put32(&out, crc)
            put32(&out, packedSize)
            put32(&out, plainSize)
            put16(&out, nameBytes.count)
            put16(&out, 0)                  // extra length
            out.append(nameBytes)
            out.append(payload)

            // Central directory header
            put32(&central, 0x0201_4B50)
            put16(&central, 20)             // version made by: 2.0, MS-DOS attributes
            put16(&central, 20)             // version needed
            put16(&central, 0x0800)
            put16(&central, method)
            put16(&central, stamp.time)
            put16(&central, stamp.date)
            put32(&central, crc)
            put32(&central, packedSize)
            put32(&central, plainSize)
            put16(&central, nameBytes.count)
            put16(&central, 0)              // extra
            put16(&central, 0)              // comment
            put16(&central, 0)              // disk number start
            put16(&central, 0)              // internal attributes
            put32(&central, 0)              // external attributes
            put32(&central, offset)
            central.append(nameBytes)
        }

        let cdOffset = UInt32(truncatingIfNeeded: out.count)
        let cdSize = UInt32(truncatingIfNeeded: central.count)
        out.append(central)

        // End of central directory
        put32(&out, 0x0605_4B50)
        put16(&out, 0)                      // this disk
        put16(&out, 0)                      // disk with the central directory
        put16(&out, files.count)
        put16(&out, files.count)
        put32(&out, cdSize)
        put32(&out, cdOffset)
        put16(&out, 0)                      // comment length
        return out
    }

    private static func dosTimestamp(_ date: Date) -> (time: Int, date: Int) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let time = ((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2)
        let day = ((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)
        return (time: time, date: day)
    }

    // MARK: CRC-32 (IEEE, as ZIP uses)

    private static let crcTable: [UInt32] = (0..<256).map { (n: Int) -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        let table = crcTable
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
