import Foundation

/// The folders Finder currently shows inside the mounts, written by the Finder extension
/// (`focus.json` in its container) and read by the app. This file is compiled by both
/// RMountCore and the standalone Finder extension, so it depends on Foundation only.
public struct FinderFocusSnapshot: Codable, Equatable {
    public static let fileName = "focus.json"

    /// Absolute folder paths, oldest first.
    public var directories: [String]
    public var writtenAt: Double

    public init(directories: [String] = [], writtenAt: Double = Date().timeIntervalSince1970) {
        self.directories = directories
        self.writtenAt = writtenAt
    }

    private enum CodingKeys: String, CodingKey { case directories, writtenAt }

    // Tolerant: a missing key reads as empty, so an older or newer writer never breaks the reader.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let all = try c.decodeIfPresent([String].self, forKey: .directories) ?? []
        directories = all.filter { $0.hasPrefix("/") }
        writtenAt = try c.decodeIfPresent(Double.self, forKey: .writtenAt) ?? 0
    }

    /// Nil when the data is missing or not a valid snapshot.
    public static func decode(_ data: Data?) -> FinderFocusSnapshot? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(FinderFocusSnapshot.self, from: data)
    }

    /// A snapshot nobody has refreshed for a while belongs to an extension that is gone.
    public func isFresh(now: Date, maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince1970 - writtenAt <= maxAge
    }
}
