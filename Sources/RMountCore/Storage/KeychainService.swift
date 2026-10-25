import Foundation
import Security

/// Which secret of a remote a Keychain item holds. A struct (not an enum) so generic
/// backends can store one item per rclone option via `.option(_:)`.
public struct SecretKind: RawRepresentable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let password = SecretKind(rawValue: "password")
    public static let keyPassphrase = SecretKind(rawValue: "keyPassphrase")
    public static let privateKey = SecretKind(rawValue: "privateKey")
    public static let localServePassword = SecretKind(rawValue: "localServePassword")
    public static let s3AccessKeyID = SecretKind(rawValue: "s3AccessKeyID")
    public static let s3SecretAccessKey = SecretKind(rawValue: "s3SecretAccessKey")

    /// Secret rclone option of a generic backend (e.g. WebDAV `pass`).
    public static func option(_ name: String) -> SecretKind {
        SecretKind(rawValue: "option.\(name)")
    }
}

public enum KeychainError: Error, Equatable {
    case osStatus(OSStatus)
    case decodingFailed
}

public final class KeychainService {
    private let serviceName: String
    private let legacyServiceNames: [String]

    /// `legacyServiceNames` are old Keychain service names (the macsh bundle id). A secret found
    /// only under one of them is returned and copied to `serviceName`; writes go to
    /// `serviceName` only, and the old items are never touched except by `delete`.
    public init(serviceName: String, legacyServiceNames: [String] = []) {
        self.serviceName = serviceName
        self.legacyServiceNames = legacyServiceNames
    }

    private func account(_ id: UUID, _ kind: SecretKind) -> String {
        "\(id.uuidString):\(kind.rawValue)"
    }

    private func baseQuery(_ id: UUID, _ kind: SecretKind, service: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? serviceName,
            kSecAttrAccount as String: account(id, kind),
        ]
    }

    public func set(remoteID: UUID, kind: SecretKind, value: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.decodingFailed }
        var query = baseQuery(remoteID, kind)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.osStatus(updateStatus) }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.osStatus(addStatus) }
        } else {
            throw KeychainError.osStatus(status)
        }
    }

    public func get(remoteID: UUID, kind: SecretKind) throws -> String? {
        if let value = try read(remoteID, kind, service: serviceName) { return value }
        for legacy in legacyServiceNames {
            // A legacy item the user cannot or will not unlock is simply not found.
            if let value = (try? read(remoteID, kind, service: legacy)) ?? nil {
                try? set(remoteID: remoteID, kind: kind, value: value)
                return value
            }
        }
        return nil
    }

    private func read(_ remoteID: UUID, _ kind: SecretKind, service: String) throws -> String? {
        var query = baseQuery(remoteID, kind, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return str
    }

    /// Removes the secret under the current name and every legacy name, so a deleted remote
    /// cannot come back through the alias.
    public func delete(remoteID: UUID, kind: SecretKind) throws {
        for service in [serviceName] + legacyServiceNames {
            let status = SecItemDelete(baseQuery(remoteID, kind, service: service) as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { continue }
            throw KeychainError.osStatus(status)
        }
    }
}
