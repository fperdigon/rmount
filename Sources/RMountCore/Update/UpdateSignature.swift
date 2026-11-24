import Foundation
import CryptoKit

/// Optional Ed25519 release signature (Sparkle EdDSA style), independent of GitHub's checksum.
///
/// Off until the maintainer generates a key: the app checks a release only when its Info.plist
/// carries `RMountUpdatePublicKey` (base64 of the 32-byte raw public key). Then every release
/// must ship `<dmg name>.sig` next to the DMG, holding the base64 (or raw 64 bytes) Ed25519
/// signature of the DMG file's bytes, made with the offline private key.
public enum UpdateSignature {
    public static let infoKey = "RMountUpdatePublicKey"

    /// The embedded public key, or nil when no key is configured (check off).
    public static func configuredPublicKey(_ info: [String: Any]?) -> Data? {
        guard let text = (info?[infoKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return Data(base64Encoded: text)
    }

    /// Name of the signature asset for a DMG asset.
    public static func signatureAssetName(for dmgName: String) -> String { dmgName + ".sig" }

    /// Accepts base64 text or the raw 64 signature bytes.
    static func decodeSignature(_ data: Data) -> Data {
        if data.count == 64 { return data }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: text) ?? data
    }

    /// Throws `releaseSignatureMissing` without a signature and `releaseSignatureInvalid` when it
    /// does not verify (also for a malformed key or signature).
    public static func verify(file: URL, signature: Data?, publicKey: Data) throws {
        guard let signature, !signature.isEmpty else { throw UpdateInstaller.InstallError.releaseSignatureMissing }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let bytes = try? Data(contentsOf: file, options: .mappedIfSafe),
              key.isValidSignature(decodeSignature(signature), for: bytes) else {
            throw UpdateInstaller.InstallError.releaseSignatureInvalid
        }
    }

    /// Downloads the `.sig` asset that belongs to `asset`; nil when the release has none.
    public static func fetch(for asset: ReleaseAsset, in release: ReleaseInfo, session: URLSession = .shared) async throws -> Data? {
        guard let sig = release.assets.first(where: { $0.name == signatureAssetName(for: asset.name) }) else { return nil }
        var req = URLRequest(url: sig.downloadURL)
        req.setValue("rmount-updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateInstaller.InstallError.downloadFailed(status) }
        return data
    }
}
