import Foundation

/// Why a remote name was refused.
public enum RemoteNameError: Error, Equatable, LocalizedError {
    case empty
    case reserved
    case invalidCharacter

    public var errorDescription: String? {
        switch self {
        case .empty: return "The name cannot be empty."
        case .reserved: return "\".\" and \"..\" cannot be used as a name."
        case .invalidCharacter: return "The name cannot contain \"/\" or control characters."
        }
    }
}

/// Remote names end up in a mountpoint path (`~/rmount/<name>`) and a volume name, so they are
/// checked on add, edit and import, and sanitized again where the path is built.
public enum RemoteName {
    /// Throws when `name` could not be used safely as a folder name. Existing remotes that were
    /// saved with a "/" keep working: the mountpoint code sanitizes instead of failing.
    public static func validate(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw RemoteNameError.empty }
        if trimmed == "." || trimmed == ".." { throw RemoteNameError.reserved }
        if trimmed.contains("/") || trimmed.unicodeScalars.contains(where: { isControl($0) }) {
            throw RemoteNameError.invalidCharacter
        }
    }

    /// A single safe path component for `name`: no separators or control characters, and no
    /// leading dots or dashes (so it can be neither `.`/`..`, hidden, nor read as an option).
    public static func pathComponent(from name: String) -> String {
        var s = String(String.UnicodeScalarView(name.unicodeScalars.filter { !isControl($0) }))
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.trimmingCharacters(in: .whitespaces)
        while let first = s.first, first == "." || first == "-" { s.removeFirst() }
        return s.isEmpty ? "rmount-mount" : s
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}
