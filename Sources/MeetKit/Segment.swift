import Foundation

public struct Segment: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum SegmentParser {
    public enum Error: Swift.Error, LocalizedError {
        case unrecognizedShape
        public var errorDescription: String? {
            "STT JSON has no top-level array nor 'segments'/'sentences' key"
        }
    }

    public static func parse(_ data: Data) throws -> [Segment] {
        let decoder = JSONDecoder()
        let raw = try JSONSerialization.jsonObject(with: data)
        let array: Any?
        if raw is [Any] {
            array = raw
        } else if let dict = raw as? [String: Any] {
            array = dict["segments"] ?? dict["sentences"]
        } else {
            array = nil
        }
        guard let array, JSONSerialization.isValidJSONObject(array) else {
            throw Error.unrecognizedShape
        }
        let arrayData = try JSONSerialization.data(withJSONObject: array)
        struct Loose: Codable {
            var text: String
            var start: Double
            var end: Double
        }
        let loose = try decoder.decode([Loose].self, from: arrayData)
        return loose
            .map { Segment(text: $0.text, start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
    }
}
