import Foundation

public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public enum STTError: Error, LocalizedError {
    case engineFailed(exitCode: Int32, logFile: URL)
    case outputMissing(expected: URL, logFile: URL)

    public var errorDescription: String? {
        switch self {
        case .engineFailed(let code, let log):
            "STT engine exited with code \(code); see \(log.path)"
        case .outputMissing(let expected, let log):
            "STT engine produced no \(expected.lastPathComponent); see \(log.path)"
        }
    }
}

public struct STTRunner: Sendable {
    public var commandTemplate: String

    public init(commandTemplate: String) {
        self.commandTemplate = commandTemplate
    }

    func render(audio: URL, outdir: URL) -> String {
        commandTemplate
            .replacingOccurrences(of: "{audio}", with: shellQuote(audio.path))
            .replacingOccurrences(of: "{outdir}", with: shellQuote(outdir.path))
    }

    public func transcribe(audio: URL, outdir: URL, log: URL) throws -> [Segment] {
        let command = render(audio: audio, outdir: outdir)

        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        try logHandle.seekToEnd()
        logHandle.write("$ \(command)\n".data(using: .utf8)!)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { logHandle.write(data) }
        }
        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            throw STTError.engineFailed(exitCode: process.terminationStatus, logFile: log)
        }

        let stem = audio.deletingPathExtension().lastPathComponent
        let expected = outdir.appendingPathComponent("\(stem).json")
        guard FileManager.default.fileExists(atPath: expected.path) else {
            throw STTError.outputMissing(expected: expected, logFile: log)
        }
        return try SegmentParser.parse(Data(contentsOf: expected))
    }
}
