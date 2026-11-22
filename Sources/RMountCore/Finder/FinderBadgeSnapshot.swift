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

    public var roots: [String]
    public var items: [Item]
    public var writtenAt: Double

    public init(roots: [String] = [], items: [Item] = [], writtenAt: Double = Date().timeIntervalSince1970) {
        self.roots = roots; self.items = items; self.writtenAt = writtenAt
    }

    public func validated() throws -> FinderBadgeSnapshot {
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
