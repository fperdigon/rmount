import Foundation

/// Reads and writes `remotes.json`.
///
/// Entries are decoded one by one: an entry this version cannot read (a backend or enum value
/// from a newer version, or a damaged entry) is skipped instead of failing the whole file. Skipped
/// entries are kept as raw JSON and written back unchanged by `save`, so a downgrade does not lose
/// the newer version's remotes. Before the first write after a load that skipped entries the old
/// file is copied to `remotes.json.bak`.
///
/// The file is a JSON array of remotes. An object form `{"version": N, "remotes": [...]}` is also
/// read (and written back in the same form), so a future format can carry a version.
public final class RemoteStore {
    /// An entry that could not be decoded and is preserved verbatim.
    public struct SkippedEntry: Equatable {
        public let index: Int
        /// Remote name when the raw entry has one, for the user-facing notice.
        public let name: String?
        public let reason: String
        fileprivate let raw: Data
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var skipped: [SkippedEntry] = []
    private var wrapped = false
    private var version: Int?
    private var backedUp = false

    public init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("remotes.json")
        self.fileManager = fileManager
    }

    var backupURL: URL { fileURL.appendingPathExtension("bak") }

    /// Entries skipped by the last `load()`.
    public var skippedEntries: [SkippedEntry] {
        lock.lock(); defer { lock.unlock() }
        return skipped
    }

    /// `version` of the file as last read (nil when absent).
    public var fileVersion: Int? {
        lock.lock(); defer { lock.unlock() }
        return version
    }

    /// Human-readable notice for the skipped entries, nil when everything loaded.
    public var skippedNotice: String? {
        let entries = skippedEntries
        guard !entries.isEmpty else { return nil }
        let names = entries.map { $0.name ?? "entry #\($0.index + 1)" }.joined(separator: ", ")
        return "\(entries.count) saved remote(s) could not be read and were left untouched: \(names). "
            + "They may come from a newer version of RMount. A backup of remotes.json is made before any change."
    }

    public func load() throws -> [Remote] {
        lock.lock(); defer { lock.unlock() }
        skipped = []
        wrapped = false
        version = nil
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let root = try JSONSerialization.jsonObject(with: data)
        let items: [Any]
        if let array = root as? [Any] {
            items = array
        } else if let object = root as? [String: Any], let array = object["remotes"] as? [Any] {
            items = array
            wrapped = true
            version = (object["version"] as? NSNumber)?.intValue
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "remotes.json is not a list of remotes"))
        }
        var remotes: [Remote] = []
        for (index, item) in items.enumerated() {
            do {
                let entry = try JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed])
                remotes.append(try JSONDecoder().decode(Remote.self, from: entry))
            } catch {
                let raw = (try? JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed, .sortedKeys])) ?? Data("null".utf8)
                skipped.append(SkippedEntry(
                    index: index,
                    name: (item as? [String: Any])?["name"] as? String,
                    reason: String(describing: error),
                    raw: raw
                ))
            }
        }
        return remotes
    }

    public func save(_ remotes: [Remote]) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var items: [Any] = []
        for remote in remotes {
            items.append(try JSONSerialization.jsonObject(with: try encoder.encode(remote)))
        }
        for entry in skipped {
            items.append(try JSONSerialization.jsonObject(with: entry.raw, options: [.fragmentsAllowed]))
        }
        let root: Any
        if wrapped {
            var object: [String: Any] = ["remotes": items]
            if let version { object["version"] = version }
            root = object
        } else {
            root = items
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        if !skipped.isEmpty, !backedUp, fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: fileURL, to: backupURL)
            backedUp = true
        }
        try data.write(to: fileURL, options: .atomic)
    }
}
