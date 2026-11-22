import Foundation
import Darwin

public enum FinderExtensionStatus: Equatable {
    case enabled
    case notEnabled
    case unknown
}

public protocol FinderExtensionStatusProviding {
    func isEnabled(bundleID: String) -> Bool
    func status(bundleID: String) -> FinderExtensionStatus
}

public extension FinderExtensionStatusProviding {
    func status(bundleID: String) -> FinderExtensionStatus {
        isEnabled(bundleID: bundleID) ? .enabled : .notEnabled
    }
}

/// A blocking probe; the prompt policy always calls it on a background queue.
public struct PluginkitFinderExtensionStatusProvider: FinderExtensionStatusProviding {
    private let executableURL: URL
    private let timeout: TimeInterval

    public init() {
        executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        timeout = 2
    }

    init(executableURL: URL, timeout: TimeInterval = 2) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func isEnabled(bundleID: String) -> Bool {
        status(bundleID: bundleID) == .enabled
    }

    public func status(bundleID: String) -> FinderExtensionStatus {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-m", "-i", bundleID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { return .unknown }
        do { try process.run() } catch { return .unknown }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        func drain() {
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                // Keep draining even if output is unexpectedly large, so the child cannot block.
                if output.count < 1_048_576 { output.append(contentsOf: buffer.prefix(count)) }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            drain()
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 0.1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < stopDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let killDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            return .unknown
        }
        drain()
        guard process.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else {
            return .unknown
        }
        return Self.parse(text, bundleID: bundleID)
    }

    static func parse(_ output: String, bundleID: String) -> FinderExtensionStatus {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let flag = trimmed.first
            let body = ["+", "-", "!"].contains(flag.map(String.init) ?? "")
                ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            guard body.hasPrefix(bundleID + "(") else { continue }
            if flag == "+" { return .enabled }
        }
        return .notEnabled
    }
}

/// Own one instance per app launch. Checking eligibility consumes that launch's notice allowance.
@MainActor
public final class FinderExtensionPromptPolicy {
    public private(set) var status: FinderExtensionStatus = .unknown
    private let preferences: UserPreferences
    private let provider: FinderExtensionStatusProviding
    private var noticeShown = false
    private var refreshGeneration = 0

    public init(preferences: UserPreferences,
                provider: FinderExtensionStatusProviding = PluginkitFinderExtensionStatusProvider()) {
        self.preferences = preferences
        self.provider = provider
    }

    @discardableResult
    public func refreshStatus(bundleID: String) async -> FinderExtensionStatus {
        refreshGeneration += 1
        let generation = refreshGeneration
        let provider = provider
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: provider.status(bundleID: bundleID))
            }
        }
        // Ignore an older lookup if a settings refresh started while it was running.
        if generation == refreshGeneration { status = result }
        return status
    }

    public func shouldShowNotice() -> Bool {
        guard preferences.showFinderBadges, !preferences.finderExtensionPromptDismissed,
              status != .enabled, !noticeShown else { return false }
        noticeShown = true
        return true
    }

    public func dismissPermanently() {
        preferences.finderExtensionPromptDismissed = true
    }
}
