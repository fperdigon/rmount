import Foundation

/// Names the app used while it was called macsh. They stay readable as aliases of the RMount
/// names so an existing install carries over its remotes, secrets and settings, and so the old
/// in-app updater can still find a download. Nothing here writes under an old name.
///
/// Remove this file and every use of it once old installs are gone (see "Legacy aliases" in
/// AGENTS.md for the list and the removal criteria).
public enum LegacyNames {
    /// `ai.rmount` (RMount) and `ai.macsh` (macsh); a `.lite` suffix is kept.
    static let currentBundleIDPrefix = "ai.rmount"
    static let bundleIDPrefix = "ai.macsh"

    /// The old bundle ids of an RMount bundle id: `ai.rmount.lite` -> `["ai.macsh.lite"]`.
    public static func legacyBundleIDs(for bundleID: String) -> [String] {
        guard bundleID.hasPrefix(currentBundleIDPrefix) else { return [] }
        return [bundleIDPrefix + bundleID.dropFirst(currentBundleIDPrefix.count)]
    }

    /// Old UserDefaults key prefix (`macsh.updateChannel`), now `rmount.`.
    static let preferenceKeyPrefix = "macsh."
    static let currentPreferenceKeyPrefix = "rmount."

    /// Old NFS mount folder (`~/macsh/<name>`), now `~/rmount/<name>`.
    static let mountDirectoryName = "macsh"

    /// Old release asset prefix (`macsh-0.1.4.dmg`, `macsh-lite-0.1.4.dmg`).
    static let assetPrefix = "macsh"

    /// Old Info.plist key holding the build commit.
    static let buildSHAInfoKey = "MacshBuildSHA"
}
