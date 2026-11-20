import AppKit
import CryptoKit
import Foundation

// MARK: - Check for Updates (Windows 1.1.5 Services/UpdateService.cs)
//
// Help > Check for Updates. Manual only, nothing runs at startup. Fetches latest.json and its signature
// from the website, checks the signature against the key built in here, then downloads the "macos" entry's DMG and
// checks its size and SHA-256 against the signed manifest. The manifest is made and signed by
// TERMinator-Windows/tools/release_manifest.py (`set macos X.Y.Z <dmg>`).
//
// Different from Windows: the app is sandboxed, so it can't replace itself in /Applications (nor can anything it
// starts). The verified DMG goes into Downloads instead; TERMinator opens it and quits, and the user drags the new
// TERMinator onto Applications.

/// The "macos" entry of latest.json.
struct UpdateInfo {
    let version: String
    let url: URL
    let size: Int64
    let sha256: String
    let notes: [String]
}

/// A failed check or download, worded like Windows `UpdateWindow.Reason`.
enum UpdateError: LocalizedError {
    case notFound
    case unreachable
    case timedOut
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "The TERMinator website has no update information yet."
        case .unreachable: return "Couldn't reach the TERMinator website. Check your internet connection."
        case .timedOut: return "The TERMinator website took too long to answer."
        case .message(let text): return text
        }
    }
}

enum UpdateService {
    private static let manifestURL = "https://deadmodemsociety.com/terminator/downloads/latest.json"

    /// ECDSA P-256 public key (SubjectPublicKeyInfo DER, base64). The private key is kept offline.
    private static let publicKey =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEsgTI8QB4DFHN4YNvsncGKoKGWZh/RqhnnpUYsKwcCLTuzNfdiTJhJhMnHq3FQuwexqLgNu57XyfbXiLrN9fq/Q=="

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "TERMinator-macOS/\(AppInfo.version)"]
        return URLSession(configuration: config)
    }()

    static var currentVersion: String { AppInfo.version }

    /// True when `version` is newer than `current`, comparing the numbers part by part ("1.1.10" > "1.1.9").
    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The macOS entry of the signed manifest. Throws if it can't be fetched or the signature is wrong.
    static func check() async throws -> UpdateInfo {
        // The query string keeps a proxy or CDN from handing back an old copy.
        let bust = "?t=\(Int(Date().timeIntervalSince1970))"
        let body = try await fetch(manifestURL + bust)
        let sigData = try await fetch(manifestURL + ".sig" + bust)

        guard let sigText = String(data: sigData, encoding: .utf8),
              let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let keyData = Data(base64Encoded: publicKey) else {
            throw UpdateError.message("The update information is damaged (bad signature).")
        }
        let key = try P256.Signing.PublicKey(derRepresentation: keyData)
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig),
              key.isValidSignature(signature, for: body) else {
            throw UpdateError.message("The update information failed its signature check.")
        }

        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw UpdateError.message("The update information is damaged.")
        }
        guard let mac = root["macos"] as? [String: Any] else {
            throw UpdateError.message("No macOS version is listed yet.")
        }
        guard let version = mac["version"] as? String,
              let urlText = mac["url"] as? String, let url = URL(string: urlText),
              let size = (mac["size"] as? NSNumber)?.int64Value,
              let sha = mac["sha256"] as? String else {
            throw UpdateError.message("The update information is damaged.")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw UpdateError.message("The update's download address isn't https.")
        }
        let notes = (mac["notes"] as? [Any])?.compactMap { $0 as? String } ?? []
        return UpdateInfo(version: version, url: url, size: size, sha256: sha, notes: notes)
    }

    private static func fetch(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw UpdateError.unreachable }
        do {
            let (data, response) = try await session.data(from: url)
            try checkStatus(response)
            return data
        } catch let error as URLError {
            throw map(error)
        }
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 { throw UpdateError.notFound }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.message("The TERMinator website answered with error \(http.statusCode).")
        }
    }

    private static func map(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled: return CancellationError()
        case .timedOut: return UpdateError.timedOut
        default: return UpdateError.unreachable
        }
    }

    /// Downloads the DMG and returns it once size and hash match, moved into Downloads (or left in the temporary
    /// folder if that fails). `progress` gets 0...1 on the main actor.
    static func download(_ info: UpdateInfo, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("TERMinator-update", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let name = info.url.lastPathComponent.isEmpty ? "TERMinator-\(info.version).dmg" : info.url.lastPathComponent
        let path = temp.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: path)
        guard FileManager.default.createFile(atPath: path.path, contents: nil),
              let out = try? FileHandle(forWritingTo: path) else {
            throw UpdateError.message("Couldn't save the download.")
        }

        do {
            defer { try? out.close() }
            let bytes: URLSession.AsyncBytes
            do {
                let (stream, response) = try await session.bytes(from: info.url)
                try checkStatus(response)
                bytes = stream
            } catch let error as URLError {
                throw map(error)
            }

            var hasher = SHA256()
            var buffer = Data()
            buffer.reserveCapacity(65536)
            var done: Int64 = 0
            var lastReport = 0.0
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count == 65536 {
                        done += Int64(buffer.count)
                        if done > info.size { throw UpdateError.message("The download is bigger than expected.") }
                        hasher.update(data: buffer)
                        try out.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                        let fraction = Double(done) / Double(max(1, info.size))
                        if fraction - lastReport >= 0.005 {
                            lastReport = fraction
                            await progress(fraction)
                        }
                    }
                }
            } catch let error as URLError {
                throw map(error)
            }
            if !buffer.isEmpty {
                done += Int64(buffer.count)
                hasher.update(data: buffer)
                try out.write(contentsOf: buffer)
            }
            await progress(1)
            if done > info.size { throw UpdateError.message("The download is bigger than expected.") }
            if done != info.size { throw UpdateError.message("The download was cut short.") }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == info.sha256.lowercased() else {
                throw UpdateError.message("The download doesn't match the signed checksum.")
            }
        } catch {
            try? FileManager.default.removeItem(at: path)
            throw error
        }

        // Somewhere the user can find it again if they close the installer window
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            let dest = downloads.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.moveItem(at: path, to: dest)) != nil {
                return dest
            }
        }
        return path
    }

    /// Opens the DMG (Finder mounts it and shows TERMinator next to Applications), then quits TERMinator and every
    /// BBS window without the "BBS windows are still open" question. False if the DMG couldn't be opened.
    @MainActor
    static func openInstallerAndQuit(_ dmg: URL) -> Bool {
        guard NSWorkspace.shared.open(dmg) else { return false }
        SessionLauncher.closeAllWithoutAsking()
        NSApp.terminate(nil)
        return true
    }
}
