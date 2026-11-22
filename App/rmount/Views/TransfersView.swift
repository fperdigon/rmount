import SwiftUI
import RMountCore

struct TransfersView: View {
    final class Navigator: ObservableObject {
        @Published var remoteID: UUID?
    }

    @ObservedObject var manager: SessionManager
    @ObservedObject var navigator: Navigator

    private var presentation: TransfersPresentation {
        TransfersPresentation(remotes: manager.sessions.map(\.remote), statuses: manager.uploadStatus,
                              selectedRemoteID: navigator.remoteID)
    }

    var body: some View {
        let snapshot = presentation
        VStack(alignment: .leading, spacing: 16) {
            Picker("Remote", selection: Binding(
                get: { presentation.selectedRemoteID },
                set: { navigator.remoteID = $0 }
            )) {
                Text("All remotes").tag(nil as UUID?)
                ForEach(snapshot.options) { option in
                    Text(option.label).tag(Optional(option.id))
                }
            }
            .pickerStyle(.menu)
            if snapshot.sections.isEmpty {
                idle
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(snapshot.sections) { section in
                            remoteSection(section)
                        }
                    }
                    .padding(2)
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: manager.sessions.map(\.id)) { _, _ in
            navigator.remoteID = presentation.selectedRemoteID
        }
    }

    private var idle: some View {
        Text("No uploads in progress")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func remoteSection(_ section: TransfersPresentation.RemoteSection) -> some View {
        let status = section.status
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if status.isStale {
                    Label("Waiting for rclone…", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                if status.hasPending || !section.rows.isEmpty {
                    Text(status.summary.text).font(.subheadline)
                    if section.scrollsFiles {
                        Text("\(section.rows.count) files • Scroll to see all files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView(.vertical) {
                            fileRows(section)
                                .padding(.trailing, 10)
                        }
                        .scrollIndicators(.automatic)
                        .frame(height: 280)
                    } else {
                        fileRows(section)
                    }
                } else if !status.isStale {
                    Text("No uploads in progress").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text(section.name).font(.headline)
        }
    }

    private func fileRows(_ section: TransfersPresentation.RemoteSection) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(section.rows) { row in
                TransferRow(transfer: row.transfer, isStale: section.status.isStale)
            }
        }
    }
}

private struct TransferRow: View {
    let transfer: TransferProgress
    let isStale: Bool

    private var stateText: String {
        switch transfer.state {
        case .queued: return "Queued"
        case .uploading: return "Uploading"
        case .finishing: return "Finishing…"
        case .retrying: return "Retrying…"
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private var byteText: String {
        guard let total = transfer.totalBytes else { return "Unknown size" }
        guard let done = transfer.bytesDone else { return bytes(total) }
        return "\(bytes(done)) of \(bytes(total))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text((transfer.path as NSString).lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .help(transfer.path)
                Spacer()
                Text(stateText).foregroundStyle(.secondary)
            }
            if (transfer.path as NSString).deletingLastPathComponent != "" {
                Text(transfer.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let fraction = transfer.fraction {
                ProgressView(value: fraction)
            } else {
                // No percentage is available while rclone is still queuing a file.
                ProgressView(value: 0)
            }
            HStack {
                Text(byteText)
                Spacer()
                if !isStale, let speed = transfer.speed, speed.isFinite, speed > 0 {
                    Text("\(bytes(Int64(min(speed, Double(Int64.max / 2)))))/s")
                }
                if !isStale, transfer.state != .finishing {
                    if let eta = transfer.eta, eta.isFinite, eta >= 0 {
                        Text(Duration.seconds(min(eta, Double(Int64.max / 2))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)) + " left")
                    } else {
                        Text("Calculating…")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
