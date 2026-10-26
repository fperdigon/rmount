/// How quickly changes made on the server show up in the mount, traded against CPU and battery.
public enum UpdateMode: String, Codable, CaseIterable, Equatable {
    case energySaver
    case responsive

    public var displayName: String {
        switch self {
        case .energySaver: return "Energy saving"
        case .responsive: return "Responsive"
        }
    }

    public var summary: String {
        switch self {
        case .energySaver:
            return "Checks the server for changes less often, so rclone and your Mac use less energy. Changes made on the server can take a few minutes to appear. Changes you make through the mount show up at once."
        case .responsive:
            return "Checks the server every few seconds so changes appear quickly, at the cost of more CPU and battery."
        }
    }
}
