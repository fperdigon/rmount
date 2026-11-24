import Foundation

public enum FinderBadgeState: Equatable {
    case waiting, uploading(Double), done, error, retrying, offline
}

/// This file is compiled by both RMountCore and the standalone Finder extension.
public struct FinderBadgeSnapshot: Codable, Equatable {
    public struct Item: Codable, Equatable {
        public var path: String
        public var state: FinderBadgeState
        public var fraction: Double? {
            if case .uploading(let value) = state { return value }
            return nil
        }

        public init(path: String, state: FinderBadgeState) { self.path = path; self.state = state }

        public var badgeIdentifier: String {
            switch state {
            case .uploading(let value):
                let bounded = value.isFinite ? min(1, max(0, value)) : 0
                return "uploading-\(min(3, Int((bounded * 4).rounded())) * 25)"
            case .waiting: return "waiting"
            case .done: return "done"
            case .error: return "error"
            case .retrying: return "retrying"
            case .offline: return "offline"
            }
        }

        private enum CodingKeys: String, CodingKey { case path, state, fraction }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            switch try c.decode(String.self, forKey: .state) {
            case "waiting": state = .waiting
            case "uploading": state = .uploading(try c.decodeIfPresent(Double.self, forKey: .fraction) ?? 0)
            case "done": state = .done
            case "error": state = .error
            case "retrying": state = .retrying
            case "offline": state = .offline
            default: throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "Unknown Finder badge state")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(fraction == nil ? badgeIdentifier : "uploading", forKey: .state)
            try c.encodeIfPresent(fraction, forKey: .fraction)
        }
    }

    /// Schema version this build writes and understands. Bump it only for a change an older reader would misread;
    /// adding optional fields does not need a bump. Snapshots without the field are version 1.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var roots: [String]
    public var items: [Item]
    public var writtenAt: Double

    public init(roots: [String] = [], items: [Item] = [], writtenAt: Double = Date().timeIntervalSince1970,
                schemaVersion: Int = FinderBadgeSnapshot.currentSchemaVersion) {
        self.roots = roots; self.items = items; self.writtenAt = writtenAt; self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, roots, items, writtenAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        roots = try c.decode([String].self, forKey: .roots)
        items = try c.decode([Item].self, forKey: .items)
        writtenAt = try c.decode(Double.self, forKey: .writtenAt)
    }

    /// Reads only the version, so a snapshot from a newer app is recognised even if its items no longer decode.
    public static func schemaVersion(of data: Data) -> Int {
        struct Probe: Decodable { var schemaVersion: Int? }
        return (try? JSONDecoder().decode(Probe.self, from: data))?.schemaVersion ?? 1
    }

    public static func isSupported(data: Data) -> Bool { schemaVersion(of: data) <= currentSchemaVersion }

    public func validated() throws -> FinderBadgeSnapshot {
        guard schemaVersion <= Self.currentSchemaVersion else { throw ValidationError.invalid }
        guard roots.allSatisfy({ $0.hasPrefix("/") }), items.allSatisfy({
            $0.path.hasPrefix("/") && ($0.fraction.map { $0.isFinite && (0...1).contains($0) } ?? true)
        }) else { throw ValidationError.invalid }
        var result = self
        result.roots = Array(Set(roots.map(finderBadgeNormalizedPath))).sorted()
        result.items = items.map { Item(path: finderBadgeNormalizedPath($0.path), state: $0.state) }
        guard Set(result.items.map(\.path)).count == result.items.count else { throw ValidationError.invalid }
        return result
    }

    private enum ValidationError: Error { case invalid }
}

/// Standardize lexically without reading metadata or resolving symlinks on a mount.
public func finderBadgeNormalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

public enum FinderBadgeConstants {
    public static let extensionBundleID = "ai.rmount.findersync"

    public static func extensionBundleID(for appBundleID: String? = Bundle.main.bundleIdentifier) -> String {
        (appBundleID ?? "ai.rmount") + ".findersync"
    }
}
