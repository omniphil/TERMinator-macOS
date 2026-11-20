import CryptoKit
import Foundation
import os.log

/// Where TRACE (TERMinator Render And Compute Engine) finds what it runs. Door modules are WebAssembly that the door
/// sends and TRACE caches by SHA-256, run by the sandboxed host (`gamesandbox`); nothing door-specific ships with
/// TERMinator. See BBSGames/Doom/ENGINE.md.
///
/// Port of the Windows client's `Services/TraceModules.cs` (the master). macOS differences: the host is the bundled
/// helper `Contents/Helpers/gamesandbox` (see `scripts/embed-trace-host.sh`), with no developer fallback path (the
/// App Sandbox can't run a binary from outside the bundle), and the data lives in
/// `Application Support/TERMinator/trace/` (inside the app's container, since the app is sandboxed).
enum TraceModules {
    /// One module: its id and version (what doors ask for), executable and frame buffer capacity. Exclusive modules
    /// (games) fill the window and take the keyboard; the others draw over terminal cells while the door keeps the
    /// keyboard. `args` is the module's command line. `cachePath` is the cached .wasm it runs from, so Settings won't
    /// delete it while it runs.
    struct Module {
        let id: String
        let version: Int
        let exePath: String
        let capacityWidth: Int
        let capacityHeight: Int
        let exclusive: Bool
        let args: [String]
        let cachePath: URL?
    }

    /// The UserDefaults keys (Windows `AppSettings.TraceEnabled` / `TraceCacheLimitMb`).
    static let keyEnabled = "trace_enabled"
    static let keyCacheLimitMb = "trace_cache_limit_mb"

    /// TRACE switched on in Preferences (default on).
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: keyEnabled) as? Bool ?? true
    }

    /// One-time move from the old 250 MB default to 500 MB (2026-10-12; Windows/Linux SettingsService.Load
    /// does the same). A 100 MB pick is kept. Called at launch, before Settings reads the value.
    static func migrateCacheDefault() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "trace_cache_500_done") else { return }
        if (d.object(forKey: keyCacheLimitMb) as? Int) == 250 {
            d.set(500, forKey: keyCacheLimitMb)
        }
        d.set(true, forKey: "trace_cache_500_done")
    }

    /// The cache limit from Preferences: 100, 250 or 500 MB (default 500).
    static var cacheLimitMb: Int {
        let value = UserDefaults.standard.object(forKey: keyCacheLimitMb) as? Int ?? 500
        return [100, 250, 500].contains(value) ? value : 500
    }

    /// Where modules keep their settings and saves: Application Support/TERMinator/trace/<id>.
    static func dataDir(_ id: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("TERMinator", isDirectory: true)
            .appendingPathComponent("trace", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// The largest WebAssembly module a door may send.
    static let maxModuleBytes = 16 * 1024 * 1024

    /// The largest asset (a WAD, a tileset, a music pack) a door may send.
    static let maxAssetBytes = 64 * 1024 * 1024

    /// The largest file a player may import (their own copy of a game or ROM: it never crosses the link). Modules
    /// read assets with 32-bit offsets, so this stays well under 2 GB.
    static let maxImportBytes: Int64 = 1 << 30

    /// The sandboxed WebAssembly host, or nil when it isn't bundled. Contents/Helpers is Apple's place for a helper
    /// tool (it is signed as nested code there); Contents/MacOS is accepted too.
    static var hostPath: String? {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let candidates = [
            contents.appendingPathComponent("Helpers/gamesandbox").path,
            contents.appendingPathComponent("MacOS/gamesandbox").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Logs once at launch where the TRACE host is, or that it's missing (then every door is told wasm=0), so a build
    /// without the helper shows up in Console.app (subsystem com.terminator.macos, category TRACE) and Xcode's console.
    static func logHostAtLaunch() {
        let log = Logger(subsystem: "com.terminator.macos", category: "TRACE")
        guard let host = hostPath else {
            log.error("TRACE helper missing: no Contents/Helpers/gamesandbox in \(Bundle.main.bundlePath, privacy: .public); doors get wasm=0 (scripts/embed-trace-host.sh didn't embed it)")
            return
        }
        let dylib = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libwasmtime.dylib").path
        if FileManager.default.fileExists(atPath: dylib) {
            log.notice("TRACE helper: \(host, privacy: .public)")
        } else {
            log.error("TRACE helper: \(host, privacy: .public), but Contents/Frameworks/libwasmtime.dylib is missing (modules won't start)")
        }
    }

    /// Where door modules are cached.
    static var cacheDir: URL { dataDir("cache") }

    /// The cached copy of a door module with this SHA-256 (lower-case hex).
    static func cachedModulePath(_ sha256: String) -> URL {
        cacheDir.appendingPathComponent(sha256 + ".wasm")
    }

    /// The cached copy of a door asset with this SHA-256; modules read these by hash, never by name.
    static func cachedAssetPath(_ sha256: String) -> URL {
        cacheDir.appendingPathComponent(sha256 + ".bin")
    }

    /// A module's own settings blob (trace_store_*). The id comes from the door, so it's cut down to plain
    /// characters first: it must name one file inside the store folder and nothing else.
    static func storePath(_ id: String) -> URL {
        var safe = String(id.filter { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "-" || ch == "_"
        }.prefix(32))
        if safe.isEmpty {
            safe = "module"
        }
        return dataDir("store").appendingPathComponent(safe + ".bin")
    }

    private struct CachedFile {
        let url: URL
        let size: Int64
        let modified: Date
    }

    /// Everything the cache holds: door modules and the assets they were sent with.
    private static func cachedFiles() -> [CachedFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [CachedFile] = []
        for url in urls where url.pathExtension == "wasm" || url.pathExtension == "bin" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            files.append(CachedFile(url: url, size: Int64(values.fileSize ?? 0),
                                    modified: values.contentModificationDate ?? .distantPast))
        }
        return files
    }

    /// Total size of the cache, in bytes.
    static func cacheSize() -> Int64 {
        cachedFiles().reduce(0) { $0 + $1.size }
    }

    /// How many modules and assets are cached.
    static func cachedModuleCount() -> Int {
        cachedFiles().count
    }

    /// Whether url is one of paths (the files a running module is using).
    static func isInUse(_ url: URL, _ paths: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return paths.contains { $0.standardizedFileURL.path == path }
    }

    /// Deletes everything cached except the files in keep (whatever a running module is using: it may still read an
    /// asset), with the sidecars, and any sidecar left without its file.
    static func clearCache(keep: [URL] = []) {
        for file in cachedFiles() where !isInUse(file.url, keep) {
            try? FileManager.default.removeItem(at: file.url)
            deleteMeta(file.url)
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else {
            return
        }
        for meta in urls where meta.pathExtension == "json" {
            if !FileManager.default.fileExists(atPath: meta.deletingPathExtension().path) {
                try? FileManager.default.removeItem(at: meta)
            }
        }
    }

    /// Marks a cached file as most recently used, for the cache limit (its modification time).
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Removes the least recently used files until the cache fits limitMb, never the ones in keep: what was just
    /// stored, and whatever a running module is using. "Used" is the file's modification time, touched on every use.
    static func enforceCacheLimit(_ limitMb: Int, keep: [URL]) {
        guard limitMb > 0 else { return }
        let limit = Int64(limitMb) * 1024 * 1024
        // Files the player imported don't count and are never trimmed: they'd have to pick them again, and a door
        // can't send them back (that's the point). They go only when the player deletes them in Settings.
        let files = cachedFiles().filter { !isImported($0.url) }.sorted { $0.modified < $1.modified }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        let keepPaths = Set(keep.map { $0.standardizedFileURL.path })
        for file in files {
            if total <= limit {
                break
            }
            if keepPaths.contains(file.url.standardizedFileURL.path) {
                continue
            }
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                total -= file.size
                deleteMeta(file.url)
            }
        }
    }

    /// A door-supplied WebAssembly module, run by the sandboxed host from the cache.
    static func wasmModule(id: String, sha256: String, exclusive: Bool) -> Module? {
        let path = cachedModulePath(sha256)
        guard let host = hostPath, FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        touch(path)   // most recently used, for the cache limit
        // Renders at the on-screen size, so allow up to a 4K-class window. The host is given the two places a module
        // may touch: the asset cache (read-only, by hash) and its own settings blob.
        let store = storePath(id)
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return Module(id: id, version: 2, exePath: host, capacityWidth: 3840, capacityHeight: 2400,
                      exclusive: exclusive,
                      args: ["-module", path.path, "-assets", cacheDir.path, "-store", store.path],
                      cachePath: path)
    }

    // MARK: - What each cached file is

    // The cache is by hash only, so beside each file sits a small sidecar, <file>.json (e.g. <sha256>.wasm.json):
    //   {"module":"doom","kind":"module"|"asset"|"imported","size":<bytes>,"bbs":"<board>",
    //    "firstCached":"2026-09-18T12:34:56Z","lastUsed":"2026-09-18T12:34:56Z"}
    // An imported file (the player's own copy, picked when a door asked for it) also has "name" (what the door
    // called it) and "grants": the boards the player allowed to use it (host:port), each asked once.
    // Written when a door's Open/Asset finds the file cached, and when an upload is stored. Files cached before
    // sidecars existed have none and list as "Unknown", with their size and file date. Same file as Windows
    // `TraceModules.RecordUse` / `ListCache`.

    private struct CacheMeta: Codable {
        var module: String?
        var kind: String?
        var size: Int64 = 0
        var bbs: String?
        var firstCached: String?
        var lastUsed: String?
        var name: String?
        var grants: [String]?
    }

    /// One cached file for Settings: its door module id (nil = Unknown, cached before sidecars), module or asset,
    /// size, the board it came from (nil = not known) and when it was last used.
    struct CacheEntry: Identifiable {
        let url: URL
        let isAsset: Bool
        let size: Int64
        let moduleId: String?
        let bbs: String?
        let lastUsed: Date
        var imported = false
        var name: String?
        var grantCount = 0

        var id: String { url.path }
    }

    /// The sidecar describing a cached file.
    private static func metaURL(_ cached: URL) -> URL {
        URL(fileURLWithPath: cached.path + ".json")
    }

    private static let timeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]   // 2026-09-18T12:34:56Z, as Windows writes it
        return formatter
    }()

    private static func readMeta(_ cached: URL) -> CacheMeta? {
        guard let data = try? Data(contentsOf: metaURL(cached)) else { return nil }
        return try? JSONDecoder().decode(CacheMeta.self, from: data)   // unreadable: Unknown until its next use
    }

    private static func deleteMeta(_ cached: URL) {
        try? FileManager.default.removeItem(at: metaURL(cached))
    }

    /// A door's module (or an asset it sent for it) was just cached or found in the cache: record what it is and that
    /// it was used now. The board is kept from the first time it's known; the module id is the latest door's.
    static func recordUse(_ cached: URL, moduleId: String, isAsset: Bool, bbs: String?) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cached.path),
              let length = attrs[.size] as? NSNumber else {
            return
        }
        var meta = readMeta(cached) ?? CacheMeta()
        let now = timeFormatter.string(from: Date())
        meta.module = String(moduleId.prefix(64))
        if meta.kind != "imported" {   // an imported file stays the player's, whoever uses it
            meta.kind = isAsset ? "asset" : "module"
        }
        meta.size = length.int64Value
        let board = bbs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if (meta.bbs ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !board.isEmpty {
            meta.bbs = board
        }
        if meta.firstCached == nil {
            meta.firstCached = now
        }
        meta.lastUsed = now
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL(cached), options: .atomic)
        }
    }

    /// What the cache holds, by module id (Unknown last), the module before its assets, then biggest first.
    static func listCache() -> [CacheEntry] {
        let entries = cachedFiles().map { file -> CacheEntry in
            let meta = readMeta(file.url)
            let id = meta?.module.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let bbs = meta?.bbs.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let used = meta?.lastUsed.flatMap { timeFormatter.date(from: $0) } ?? file.modified
            return CacheEntry(url: file.url, isAsset: file.url.pathExtension == "bin", size: file.size,
                              moduleId: id, bbs: bbs, lastUsed: used,
                              imported: meta?.kind == "imported", name: meta?.name,
                              grantCount: meta?.grants?.count ?? 0)
        }
        return entries.sorted { a, b in
            if (a.moduleId == nil) != (b.moduleId == nil) {
                return b.moduleId == nil
            }
            let idA = a.moduleId?.lowercased() ?? "", idB = b.moduleId?.lowercased() ?? ""
            if idA != idB {
                return idA < idB
            }
            if a.isAsset != b.isAsset {
                return !a.isAsset
            }
            return a.size > b.size
        }
    }

    /// Deletes one cached file and its sidecar. Refused (false) when a running module is using it (inUse), or when
    /// url isn't a file in the cache.
    @discardableResult
    static func deleteCached(_ url: URL, inUse: [URL]) -> Bool {
        guard cachedFiles().contains(where: { isInUse($0.url, [url]) }), !isInUse(url, inUse) else {
            return false
        }
        guard (try? FileManager.default.removeItem(at: url)) != nil else {
            return false
        }
        deleteMeta(url)
        return true
    }

    // MARK: - Files the player imported (their own copy of a game or ROM)

    /// Whether a cached file is one the player imported.
    static func isImported(_ cached: URL) -> Bool {
        readMeta(cached)?.kind == "imported"
    }

    /// Whether the player allowed this board (host:port) to use an imported file.
    static func isGranted(_ cached: URL, bbsKey: String) -> Bool {
        readMeta(cached)?.grants?.contains { $0.caseInsensitiveCompare(bbsKey) == .orderedSame } ?? false
    }

    /// What the door called an imported file when it was picked.
    static func importedName(_ cached: URL) -> String? {
        readMeta(cached)?.name
    }

    /// Records a file the player just imported (name = what the door called it), or a board they just allowed to
    /// use one already imported.
    static func recordImport(_ cached: URL, name: String, bbsKey: String, bbsName: String?) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cached.path),
              let length = attrs[.size] as? NSNumber else {
            return
        }
        var meta = readMeta(cached) ?? CacheMeta()
        let now = timeFormatter.string(from: Date())
        meta.kind = "imported"
        meta.size = length.int64Value
        if meta.name == nil {
            meta.name = name
        }
        var grants = meta.grants ?? []
        if !grants.contains(where: { $0.caseInsensitiveCompare(bbsKey) == .orderedSame }) {
            grants.append(bbsKey)
        }
        meta.grants = grants
        let board = bbsName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if (meta.bbs ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !board.isEmpty {
            meta.bbs = board
        }
        if meta.firstCached == nil {
            meta.firstCached = now
        }
        meta.lastUsed = now
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL(cached), options: .atomic)
        }
    }

    /// Copies the player's file into the cache while working out its SHA-256, in one pass (a big file is read once).
    /// Returns the hash, and whether it was kept: only when it's one of `expected` (what the door asked for), stored
    /// as <sha256>.bin like any asset so a module reads it by hash. A nil hash means the file couldn't be read or is
    /// bigger than `maxImportBytes`.
    static func importFile(_ source: URL, expected: [String]) -> (hash: String?, kept: Bool) {
        let temp = cacheDir.appendingPathComponent("import-\(UUID().uuidString).tmp")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: source.path),
              let length = (attrs[.size] as? NSNumber)?.int64Value, length <= maxImportBytes,
              let input = try? FileHandle(forReadingFrom: source) else {
            return (nil, false)
        }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let output = try? FileHandle(forWritingTo: temp) else {
            return (nil, false)
        }
        var sha = SHA256()
        var ok = true
        while true {
            guard let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            sha.update(data: chunk)
            do {
                try output.write(contentsOf: chunk)
            } catch {
                ok = false
                break
            }
        }
        try? output.close()
        guard ok else { return (nil, false) }
        let hash = sha.finalize().map { String(format: "%02x", $0) }.joined()
        guard expected.contains(where: { $0.caseInsensitiveCompare(hash) == .orderedSame }) else {
            return (hash, false)   // not the copy this door knows
        }
        let target = cachedAssetPath(hash)
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.moveItem(at: temp, to: target)) != nil else {
            return (hash, false)
        }
        return (hash, true)
    }

    /// Whether modules can use the graphics card: the sandbox host draws with WebGPU (libwgpu_native.dylib, in the
    /// bundle's Frameworks). Without the library the host still runs and a module falls back to the CPU, so doors
    /// check for gpu=1. gpu2=1: the host has trace_gpu.h version 2 (mipmaps, indirect draws, several targets, pass
    /// timings, a present that doesn't wait), which a module importing those calls needs; embed-trace-host.sh builds
    /// it from the same sources.
    static var gpuInstalled: Bool {
        guard hostPath != nil else { return false }
        let lib = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/libwgpu_native.dylib").path
        return FileManager.default.fileExists(atPath: lib)
    }

    /// What this TERMinator can run, for the reply to a door's TRACE;Query. A door reads the flags it cares about and
    /// picks a module to match: wasm (it can run a module a door sends), audio, assets (big files by hash), send
    /// (the module can answer the door), store (settings that survive), tick (steady updates for a game), gz (it takes
    /// gzip uploads: Put ... enc=gz, TraceSessionManager.gunzip).
    /// Empty when TRACE is switched off in Preferences, and then the Query goes unanswered, as on a terminal
    /// without TRACE.
    static func capabilities(enabled: Bool) -> String {
        if !enabled {
            return ""
        }
        if hostPath == nil {
            return "wasm=0"
        }
        return "wasm=1;audio=1;assets=1;send=1;store=1;tick=1;text=1;mouse=1;pad=1;import=1;bin=1;gz=1;paste=1;url=1;keep=1"
            + (gpuInstalled ? ";gpu=1;gpu2=1" : "")
    }
}
