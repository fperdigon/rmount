import Foundation

public enum AppPaths {
    /// `~/Library/Application Support/<bundleID>`, created on first use.
    ///
    /// When it does not exist yet and a directory of an old bundle id does (`legacyBundleIDs`),
    /// the old one is copied over first, all or nothing, so remotes, known hosts and logs follow
    /// the rename. The old directory is left in place so an older version keeps working.
    public static func applicationSupport(
        bundleID: String,
        legacyBundleIDs: [String] = [],
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            for legacy in legacyBundleIDs {
                let old = base.appendingPathComponent(legacy, isDirectory: true)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let staging = base.appendingPathComponent("\(bundleID).migrating", isDirectory: true)
                try? fileManager.removeItem(at: staging)
                do {
                    try fileManager.copyItem(at: old, to: staging)
                    try fileManager.moveItem(at: staging, to: dir)
                } catch {
                    try? fileManager.removeItem(at: staging)
                    throw error
                }
                try? Data(legacy.utf8).write(to: dir.appendingPathComponent(".migrated-from"))
                break
            }
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
