import Foundation

public struct Session: Equatable, Sendable {
    public var directory: URL
    public var micWAV: URL { directory.appendingPathComponent("mic.wav") }
    public var systemWAV: URL { directory.appendingPathComponent("system.wav") }
    public var micM4A: URL { directory.appendingPathComponent("mic.m4a") }
    public var systemM4A: URL { directory.appendingPathComponent("system.m4a") }
    public var micJSON: URL { directory.appendingPathComponent("mic.json") }
    public var systemJSON: URL { directory.appendingPathComponent("system.json") }
    public var transcriptMD: URL { directory.appendingPathComponent("transcript.md") }
    public var metaJSON: URL { directory.appendingPathComponent("meta.json") }
    public var logFile: URL { directory.appendingPathComponent("pipeline.log") }

    public init(directory: URL) { self.directory = directory }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func loadMeta() throws -> SessionMeta {
        try Self.decoder.decode(SessionMeta.self, from: Data(contentsOf: metaJSON))
    }

    public func saveMeta(_ meta: SessionMeta) throws {
        try Self.encoder.encode(meta).write(to: metaJSON, options: .atomic)
    }

    public func displayTitle(meta: SessionMeta) -> String {
        if let title = meta.title { return title }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Call \(formatter.string(from: meta.startedAt))"
    }
}

public struct SessionStore: Sendable {
    public var rootDir: URL

    public init(rootDir: URL) { self.rootDir = rootDir }

    public func createSession(at date: Date) throws -> Session {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let base = formatter.string(from: date)
        let fm = FileManager.default
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)

        var candidate = rootDir.appendingPathComponent(base)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            n += 1
            candidate = rootDir.appendingPathComponent("\(base)-\(n)")
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return Session(directory: candidate.standardizedFileURL)
    }

    public func allSessions() throws -> [Session] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDir.path) else { return [] }
        return try fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && fm.fileExists(atPath: url.appendingPathComponent("meta.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in Session(directory: url.standardizedFileURL) }
    }
}
