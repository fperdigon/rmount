import Foundation

/// A snapshot for the Transfers window, independent of session and UI state.
public struct TransfersPresentation {
    public struct RemoteOption: Identifiable {
        public let id: UUID
        public let label: String
    }

    public struct FileRow: Identifiable {
        public struct ID: Hashable {
            public let path: String
            public let occurrence: Int
        }

        public let id: ID
        public let transfer: TransferProgress
    }

    public struct RemoteSection: Identifiable {
        public let id: UUID
        public let name: String
        public let status: UploadStatus
        public let rows: [FileRow]
        public var scrollsFiles: Bool { rows.count > 3 }
    }

    public let selectedRemoteID: UUID?
    public let options: [RemoteOption]
    public let sections: [RemoteSection]

    public init(remotes: [Remote], statuses: [UUID: UploadStatus], selectedRemoteID: UUID?) {
        let selection = selectedRemoteID.flatMap { id in remotes.contains { $0.id == id } ? id : nil }
        self.selectedRemoteID = selection
        options = remotes.map {
            RemoteOption(id: $0.id, label: "\($0.name) (\(statuses[$0.id]?.uploadingCount ?? 0) active)")
        }
        sections = remotes.compactMap { remote in
            let status = statuses[remote.id] ?? UploadStatus()
            if let selection {
                guard remote.id == selection else { return nil }
            } else {
                guard status.hasPending || !status.transfers.isEmpty || status.isStale else { return nil }
            }
            var occurrences: [String: Int] = [:]
            let rows = status.transfers.map { transfer in
                let occurrence = occurrences[transfer.path, default: 0]
                occurrences[transfer.path] = occurrence + 1
                return FileRow(id: .init(path: transfer.path, occurrence: occurrence), transfer: transfer)
            }
            return RemoteSection(id: remote.id, name: remote.name, status: status, rows: rows)
        }
    }
}
