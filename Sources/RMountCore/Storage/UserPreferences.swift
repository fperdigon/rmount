import Foundation

/// Lightweight wrapper around UserDefaults for app-wide settings.
public final class UserPreferences {
    private let defaults: UserDefaults

    /// `legacyDomains` are the preference domains of the old bundle ids (`ai.macsh`). Values the
    /// user set there, under the old `macsh.*` key names, are copied once to the `rmount.*` keys;
    /// the old values stay where they are, so an older version keeps working.
    public init(defaults: UserDefaults = .standard, legacyDomains: [String] = []) {
        self.defaults = defaults
        migrateLegacyValues(from: legacyDomains)
    }

    private static let defaultProtocolName = "defaultProtocol"
    private static let customRclonePathName = "customRclonePath"
    private static let updateChannelName = "updateChannel"
    private static let autoCheckUpdatesName = "autoCheckUpdates"
    private static let lastUpdateCheckName = "lastUpdateCheck"
    private static let skippedUpdateTagName = "skippedUpdateTag"
    private static let allNames = [
        defaultProtocolName, customRclonePathName, updateChannelName,
        autoCheckUpdatesName, lastUpdateCheckName, skippedUpdateTagName,
    ]
    private static let migratedKey = LegacyNames.currentPreferenceKeyPrefix + "legacyPreferencesMigrated"

    private static func key(_ name: String) -> String { LegacyNames.currentPreferenceKeyPrefix + name }
    private static var defaultProtocolKey: String { key(defaultProtocolName) }
    private static var customRclonePathKey: String { key(customRclonePathName) }
    private static var updateChannelKey: String { key(updateChannelName) }
    private static var autoCheckUpdatesKey: String { key(autoCheckUpdatesName) }
    private static var lastUpdateCheckKey: String { key(lastUpdateCheckName) }
    private static var skippedUpdateTagKey: String { key(skippedUpdateTagName) }

    private func migrateLegacyValues(from legacyDomains: [String]) {
        guard defaults.object(forKey: Self.migratedKey) == nil else { return }
        for name in Self.allNames {
            let new = Self.key(name)
            guard defaults.object(forKey: new) == nil else { continue }
            let old = LegacyNames.preferenceKeyPrefix + name
            var value = defaults.object(forKey: old)
            if value == nil {
                for domain in legacyDomains {
                    value = defaults.persistentDomain(forName: domain)?[old]
                    if value != nil { break }
                }
            }
            if let value { defaults.set(value, forKey: new) }
        }
        defaults.set(true, forKey: Self.migratedKey)
    }

    public var defaultProtocol: MountProtocol {
        get {
            if let raw = defaults.string(forKey: Self.defaultProtocolKey),
               let p = MountProtocol(rawValue: raw) {
                return p
            }
            return .webdav
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.defaultProtocolKey)
        }
    }

    /// User-supplied path to an rclone binary. When set, takes priority over the
    /// bundled binary and Homebrew fallbacks in `RcloneBinary.resolve(prefs:)`.
    public var customRclonePath: String? {
        get {
            let s = defaults.string(forKey: Self.customRclonePathKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: Self.customRclonePathKey)
            } else {
                defaults.removeObject(forKey: Self.customRclonePathKey)
            }
        }
    }

    /// Which releases "Check for updates" offers. Defaults to stable.
    public var updateChannel: UpdateChannel {
        get { defaults.string(forKey: Self.updateChannelKey).flatMap(UpdateChannel.init(rawValue:)) ?? .stable }
        set { defaults.set(newValue.rawValue, forKey: Self.updateChannelKey) }
    }

    /// Check for an update in the background about once a day. On by default.
    public var autoCheckUpdates: Bool {
        get { defaults.object(forKey: Self.autoCheckUpdatesKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoCheckUpdatesKey) }
    }

    public var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Self.lastUpdateCheckKey) as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.lastUpdateCheckKey) }
            else { defaults.removeObject(forKey: Self.lastUpdateCheckKey) }
        }
    }

    /// Release tag the user chose to skip; only silent background checks honour it.
    public var skippedUpdateTag: String? {
        get { defaults.string(forKey: Self.skippedUpdateTagKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.skippedUpdateTagKey) }
            else { defaults.removeObject(forKey: Self.skippedUpdateTagKey) }
        }
    }

    /// True when the automatic check is enabled and the last one was over `interval` ago.
    public func updateCheckDue(now: Date = Date(), interval: TimeInterval = 24 * 3600) -> Bool {
        guard autoCheckUpdates else { return false }
        guard let last = lastUpdateCheck else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}
