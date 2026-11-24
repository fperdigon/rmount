import Foundation

/// Detects files rclone left in its default, shared cache (`~/Library/Caches/rclone`) before each
/// remote got its own `--cache-dir`. Read-only: nothing here deletes or moves anything.
///
/// rclone lays its VFS cache out as `<cache-dir>/vfs/<fs name>/<remote root>` for data and
/// `<cache-dir>/vfsMeta/<fs name>/<remote root>` for metadata (`vfs/vfscache/cache.go`,
/// `createRootDirs`). RMount's section is `r`, and rclone may append a hash to the fs name
/// (`r{abc12}`), so every directory whose name is `r` or starts with `r{` is checked.
public enum LegacyVFSCache {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/rclone", isDirectory: true)
    }

    /// True when the legacy cache may still hold entries for `remotePath`, or when it cannot be
    /// told safely (unusual characters in the path, which rclone encodes on disk). Errs towards true.
    public static func hasEntries(root: URL, remotePath: String, fileManager: FileManager = .default) -> Bool {
        let section = RcloneConfigBuilder.sectionName
        let components = remotePath.split(separator: "/").map(String.init)
        let plain = components.allSatisfy { $0.range(of: #"^[A-Za-z0-9._ -]+$"#, options: .regularExpression) != nil }
            && !components.contains("..")
        for area in ["vfs", "vfsMeta"] {
            let areaURL = root.appendingPathComponent(area, isDirectory: true)
            guard let children = try? fileManager.contentsOfDirectory(atPath: areaURL.path) else { continue }
            for name in children where name == section || name.hasPrefix("\(section){") {
                let fsDir = areaURL.appendingPathComponent(name, isDirectory: true)
                let target = plain ? components.reduce(fsDir) { $0.appendingPathComponent($1) } : fsDir
                if !isEmptyOrMissing(target, fileManager) { return true }
            }
        }
        return false
    }

    private static func isEmptyOrMissing(_ url: URL, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return true }
        if !isDir.boolValue { return false }
        return ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty
    }
}
