import Foundation
import Combine
import Darwin

@MainActor
public final class SessionManager: ObservableObject {
    @Published public private(set) var sessions: [RemoteSession] = []
    @Published public private(set) var uploadStatus: [UUID: UploadStatus] = [:]

    private var uploadMonitors: [UUID: UploadMonitor] = [:]
    private var uploadGenerations: [UUID: UUID] = [:]
    private let controlClient: (RcloneProcess.Spawned) -> RcloneControlClient
    private let finderProgressPublisher: FinderProgressPublisher
    private let finderBadgeTracker: FinderBadgeTracker
    private let preferences: UserPreferences
    private var finderProgressPreferenceCancellable: AnyCancellable?
    private var finderBadgesPreferenceCancellable: AnyCancellable?

    private let store: RemoteStore
    private let keychain: KeychainService
    private let mounter: Mounter
    private let logsDir: URL
    /// Parent of the per-remote rclone VFS cache directories (`<cacheRoot>/<remote UUID>`).
    private let cacheRoot: URL
    /// rclone's default shared cache, where pre-migration uploads may still wait.
    private let legacyCacheRoot: URL
    /// Remotes mounted on the legacy cache; each moves to its own dir after a mount with no pending uploads.
    private var legacyCacheMounts: Set<UUID> = []
    private let rcloneBinary: URL
    private let hostKeyVerifier: HostKeyVerifier?
    /// Tests only: lets an SFTP remote run without a host-key verifier. In the app a missing
    /// verifier is an error, never "no host-key checking".
    var allowMissingHostKeyVerifier = false

    /// How long `mount` waits for rclone to start listening. Overridable for tests.
    public var portWaitTimeout: TimeInterval = 30

    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var sessionCancellables: [UUID: AnyCancellable] = [:]

    public init(
        store: RemoteStore,
        keychain: KeychainService,
        mounter: Mounter,
        logsDir: URL,
        cacheRoot: URL? = nil,
        legacyCacheRoot: URL? = nil,
        rcloneBinary: URL,
        hostKeyVerifier: HostKeyVerifier? = nil,
        preferences: UserPreferences = UserPreferences(),
        finderProgressFactory: FinderProgressFactory? = nil,
        finderBadgeTracker: FinderBadgeTracker? = nil,
        controlClient: @escaping (RcloneProcess.Spawned) -> RcloneControlClient = {
            URLSessionRcloneControlClient(port: $0.rcPort, user: $0.rcUser, password: $0.rcPassword)
        }
    ) {
        self.store = store
        self.keychain = keychain
        self.mounter = mounter
        self.logsDir = logsDir
        self.cacheRoot = cacheRoot ?? logsDir.deletingLastPathComponent().appendingPathComponent("cache", isDirectory: true)
        self.legacyCacheRoot = legacyCacheRoot ?? LegacyVFSCache.defaultRoot
        self.rcloneBinary = rcloneBinary
        self.hostKeyVerifier = hostKeyVerifier
        self.controlClient = controlClient
        self.preferences = preferences
        self.finderProgressPublisher = FinderProgressPublisher(
            factory: finderProgressFactory, isEnabled: preferences.showFinderUploadProgress)
        self.finderBadgeTracker = finderBadgeTracker ?? FinderBadgeTracker(isEnabled: preferences.showFinderBadges)
        self.finderBadgeTracker.isEnabled = preferences.showFinderBadges
        finderBadgesPreferenceCancellable = NotificationCenter.default
            .publisher(for: UserPreferences.showFinderBadgesDidChange)
            .sink { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.updateFinderBadgesPreference() }
                } else {
                    Task { @MainActor [weak self] in self?.updateFinderBadgesPreference() }
                }
            }
        finderProgressPreferenceCancellable = NotificationCenter.default
            .publisher(for: UserPreferences.showFinderUploadProgressDidChange)
            .sink { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.updateFinderProgressPreference() }
                } else {
                    Task { @MainActor [weak self] in self?.updateFinderProgressPreference() }
                }
            }
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    private func updateFinderProgressPreference() {
        let enabled = preferences.showFinderUploadProgress
        guard finderProgressPublisher.isEnabled != enabled else { return }
        finderProgressPublisher.isEnabled = enabled
        for (remoteID, status) in uploadStatus {
            finderProgressPublisher.sync(remoteID: remoteID,
                                         mountpoint: sessions.first(where: { $0.id == remoteID })?.mountpoint,
                                         status: status)
        }
    }

    private func updateFinderBadgesPreference() {
        let enabled = preferences.showFinderBadges
        guard finderBadgeTracker.isEnabled != enabled else { return }
        finderBadgeTracker.isEnabled = enabled
        for session in sessions where session.mountpoint != nil {
            finderBadgeTracker.sync(remoteID: session.id, remoteName: session.remote.name,
                                    mountpoint: session.mountpoint,
                                    status: uploadStatus[session.id] ?? UploadStatus())
        }
    }

    public func pendingUploads() -> [(remoteName: String, status: UploadStatus)] {
        sessions.compactMap { session in
            guard let status = uploadStatus[session.id], status.hasPending else { return nil }
            return (remoteName: session.remote.name, status: status)
        }
    }

    func startUploadMonitor(remoteID: UUID, client: RcloneControlClient) {
        stopUploadMonitor(remoteID: remoteID)
        if let session = sessions.first(where: { $0.id == remoteID }) {
            finderBadgeTracker.sync(remoteID: remoteID, remoteName: session.remote.name,
                                    mountpoint: session.mountpoint, status: UploadStatus())
        }
        let generation = UUID()
        uploadGenerations[remoteID] = generation
        uploadMonitors[remoteID] = UploadMonitor(client: client) { [weak self] status in
            guard let self, self.uploadGenerations[remoteID] == generation else { return }
            self.uploadStatus[remoteID] = status
            if !status.hasPending, !status.isStale, self.legacyCacheMounts.contains(remoteID) {
                self.markCacheMigrated(remoteID)
            }
            if let session = self.sessions.first(where: { $0.id == remoteID }) {
                self.finderBadgeTracker.sync(remoteID: remoteID, remoteName: session.remote.name,
                                            mountpoint: session.mountpoint, status: status)
            }
            self.finderProgressPublisher.sync(
                remoteID: remoteID,
                mountpoint: self.sessions.first(where: { $0.id == remoteID })?.mountpoint,
                status: status)
        }
    }

    public func refreshUploadStatus(remoteID: UUID? = nil) async {
        for id in Array(uploadMonitors.keys) where remoteID == nil || id == remoteID {
            // Use the same serialized snapshot as background polling, including its
            // partial-failure and stale handling. Look up each monitor after awaiting
            // the previous one so a remount cannot refresh an obsolete client.
            guard let monitor = uploadMonitors[id] else { continue }
            await monitor.refresh()
        }
    }

    private func stopUploadMonitor(remoteID: UUID) {
        uploadGenerations[remoteID] = nil
        uploadMonitors.removeValue(forKey: remoteID)?.stop()
        uploadStatus[remoteID] = nil
        finderProgressPublisher.clear(remoteID: remoteID)
        finderBadgeTracker.clear(remoteID: remoteID)
    }

    /// Notice about `remotes.json` entries this version could not read (kept untouched on disk);
    /// nil when everything loaded. Non-fatal: the app shows it and carries on.
    public var storeNotice: String? { store.skippedNotice }

    public func reload() throws {
        let remotes = try store.load()
        let existingByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let newSessions = remotes.map { existingByID[$0.id] ?? RemoteSession(remote: $0) }
        for id in uploadMonitors.keys where !newSessions.contains(where: { $0.id == id }) {
            stopUploadMonitor(remoteID: id)
        }
        sessions = newSessions
        // Re-subscribe each session's status changes so the menu (which subscribes to
        // $sessions) rebuilds when a status flips. Without this, mount → unmount label
        // never updates because the array's reference doesn't change on transition.
        sessionCancellables.removeAll()
        for s in newSessions {
            sessionCancellables[s.id] = s.$status
                .dropFirst()
                .sink { [weak self] _ in
                    guard let self else { return }
                    // Re-publish the same array so subscribers of $sessions wake up.
                    self.sessions = self.sessions
                }
        }
    }

    /// Called once at app launch after `reload()` to mount every remote with autoMount=true.
    /// First reconciles stale mounts left behind by a prior instance that died via
    /// SIGKILL/crash — without this, every relaunch would pile up `<name>-1`,
    /// `<name>-2`, … entries in /Volumes since NetFS auto-numbers collisions.
    public func autoMountAll() {
        let mounter = self.mounter
        let volnames = sessions.map { mounter.volumeName(from: $0.remote.name) }
        Task { @MainActor [weak self] in
            // pgrep / mount / diskutil: keep them off the main thread.
            try? await Self.offMain {
                for v in volnames { mounter.reconcileStaleMount(volumeName: v) }
                mounter.reconcileLeftoverNFSMounts()
                mounter.reconcileOrphanedRclone()
            }
            guard let self else { return }
            for session in self.sessions where session.remote.autoMount {
                self.scheduleMount(remoteID: session.id, attempt: 0)
            }
        }
    }

    /// Runs blocking work (Process.waitUntilExit, NetFS, sockets) on a background queue so
    /// the main thread, and with it the menu bar item, stays responsive.
    nonisolated static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try work() })
            }
        }
    }

    private func scheduleMount(remoteID: UUID, attempt: Int) {
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.mount(remoteID: remoteID)
                self.retryTasks[remoteID] = nil
            } catch {
                if let session = self.sessions.first(where: { $0.id == remoteID }),
                   case .failed(let reason) = session.status,
                   Self.isPermanentAuthFailure(reason) {
                    self.retryTasks[remoteID] = nil
                    let hint = "Sign-in expired. Edit the remote and sign in again."
                    if !reason.hasSuffix(hint) {
                        session.transition(to: .failed(reason: reason + "\n" + hint))
                    }
                    return
                }
                let nextAttempt = attempt + 1
                let delay = Self.backoffDelay(attempt: nextAttempt)
                guard delay > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if !Task.isCancelled {
                    self.scheduleMount(remoteID: remoteID, attempt: nextAttempt)
                }
            }
        }
    }

    static func isPermanentAuthFailure(_ reason: String) -> Bool {
        let text = reason.lowercased()
        return ["invalid_grant", "couldn't fetch token", "cannot fetch token", "token expired"]
            .contains { text.contains($0) }
    }

    /// Exponential backoff: 1s, 5s, 30s, then 5min cap.
    static func backoffDelay(attempt: Int) -> TimeInterval {
        switch attempt {
        case 1: return 1
        case 2: return 5
        case 3: return 30
        case 4...: return 300
        default: return 0
        }
    }

    public func add(_ remote: Remote, sftpSecrets: SFTPSecrets? = nil, s3Secrets: S3Secrets? = nil, ftpSecrets: FTPSecrets? = nil, optionSecrets: [String: String]? = nil) throws {
        try RemoteName.validate(remote.name)
        if let s = sftpSecrets {
            if let pwd = s.password { try keychain.set(remoteID: remote.id, kind: .password, value: pwd) }
            if let pp = s.keyPassphrase { try keychain.set(remoteID: remote.id, kind: .keyPassphrase, value: pp) }
            if let keyPath = s.privateKeyPath { try keychain.set(remoteID: remote.id, kind: .privateKey, value: keyPath) }
        }
        if let s = s3Secrets {
            try keychain.set(remoteID: remote.id, kind: .s3AccessKeyID, value: s.accessKeyID)
            try keychain.set(remoteID: remote.id, kind: .s3SecretAccessKey, value: s.secretAccessKey)
        }
        if let s = ftpSecrets {
            try keychain.set(remoteID: remote.id, kind: .password, value: s.password)
        }
        for (name, value) in optionSecrets ?? [:] {
            try keychain.set(remoteID: remote.id, kind: .option(name), value: value)
        }
        var all = try store.load()
        all.append(remote)
        try store.save(all)
        try reload()
    }

    /// Updates an existing remote in `remotes.json`. Backend type cannot change.
    /// Secret fields (`SFTPSecrets.password`, `S3Secrets.accessKeyID`/`secretAccessKey`,
    /// `FTPSecrets.password`, `optionSecrets`) are interpreted as "blank means keep existing": only
    /// non-nil and non-empty values overwrite the keychain. The session reference
    /// is preserved so an in-flight `.starting` status survives the update.
    public func update(_ remote: Remote, sftpSecrets: SFTPSecrets? = nil, s3Secrets: S3Secrets? = nil, ftpSecrets: FTPSecrets? = nil, optionSecrets: [String: String]? = nil) throws {
        try RemoteName.validate(remote.name)
        if let s = sftpSecrets {
            if let pwd = s.password, !pwd.isEmpty { try keychain.set(remoteID: remote.id, kind: .password, value: pwd) }
            if let pp = s.keyPassphrase, !pp.isEmpty { try keychain.set(remoteID: remote.id, kind: .keyPassphrase, value: pp) }
            if let keyPath = s.privateKeyPath, !keyPath.isEmpty { try keychain.set(remoteID: remote.id, kind: .privateKey, value: keyPath) }
        }
        if let s = s3Secrets {
            if !s.accessKeyID.isEmpty { try keychain.set(remoteID: remote.id, kind: .s3AccessKeyID, value: s.accessKeyID) }
            if !s.secretAccessKey.isEmpty { try keychain.set(remoteID: remote.id, kind: .s3SecretAccessKey, value: s.secretAccessKey) }
        }
        if let s = ftpSecrets, !s.password.isEmpty {
            try keychain.set(remoteID: remote.id, kind: .password, value: s.password)
        }
        for (name, value) in optionSecrets ?? [:] where !value.isEmpty {
            try keychain.set(remoteID: remote.id, kind: .option(name), value: value)
        }
        var all = try store.load()
        guard let idx = all.firstIndex(where: { $0.id == remote.id }) else {
            throw NSError(domain: "rmount", code: 2, userInfo: [NSLocalizedDescriptionKey: "Remote not found"])
        }
        all[idx] = remote
        try store.save(all)
        // Mutate the existing RemoteSession's `remote` in place rather than recreating
        // it, so any subscribers (and the session's status) are preserved. Then re-emit.
        if let s = sessions.first(where: { $0.id == remote.id }) {
            s.remote = remote
            sessions = sessions
        } else {
            try reload()
        }
    }

    /// Unmounts (off the main actor, so the menu bar stays responsive), then removes the remote.
    public func delete(_ remoteID: UUID) async throws {
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = nil
        let hadPendingUploads = uploadStatus[remoteID]?.hasPending ?? false
        if let attempt = mountAttempts[remoteID] { abort(attempt, unmountBlocking: true) }
        if let session = sessions.first(where: { $0.id == remoteID }), case .mounted = session.status {
            try? await unmount(remoteID: remoteID, force: true)
        }
        try? keychain.delete(remoteID: remoteID, kind: .password)
        try? keychain.delete(remoteID: remoteID, kind: .keyPassphrase)
        try? keychain.delete(remoteID: remoteID, kind: .privateKey)
        try? keychain.delete(remoteID: remoteID, kind: .localServePassword)
        try? keychain.delete(remoteID: remoteID, kind: .s3AccessKeyID)
        try? keychain.delete(remoteID: remoteID, kind: .s3SecretAccessKey)
        if let removed = sessions.first(where: { $0.id == remoteID })?.remote,
           case .rclone(let cfg) = removed.backend {
            for opt in cfg.secretOptions { try? keychain.delete(remoteID: remoteID, kind: .option(opt.name)) }
        }
        var all = try store.load()
        all.removeAll { $0.id == remoteID }
        try store.save(all)
        // Keep the cache when uploads were still pending: it holds the only copy of those files.
        if !hadPendingUploads { try? FileManager.default.removeItem(at: cacheDir(for: remoteID)) }
        try reload()
    }

    /// `--cache-dir` for this mount. A remote saved before per-remote caches keeps rclone's old shared
    /// cache (no flag) while that cache may still hold its entries, so no pending upload is stranded;
    /// otherwise it switches to its own dir at once. The old cache is never deleted.
    private func cacheArgs(for remote: Remote, remotePath: String) -> [String] {
        if !remote.cacheMigrated {
            if LegacyVFSCache.hasEntries(root: legacyCacheRoot, remotePath: remotePath) {
                legacyCacheMounts.insert(remote.id)
                return []
            }
            markCacheMigrated(remote.id)
        }
        return MountOptions.cacheDirArgs(cacheDir(for: remote.id))
    }

    /// Persists that the remote uses its own cache dir (from the next mount on).
    func markCacheMigrated(_ remoteID: UUID) {
        legacyCacheMounts.remove(remoteID)
        guard var all = try? store.load(), let i = all.firstIndex(where: { $0.id == remoteID }),
              !all[i].cacheMigrated else { return }
        all[i].cacheMigrated = true
        guard (try? store.save(all)) != nil else { return }
        sessions.first(where: { $0.id == remoteID })?.remote.cacheMigrated = true
    }

    /// rclone's own VFS cache directory for one remote, never shared with another remote or
    /// with other rclone processes (rclone's default is one `~/Library/Caches/rclone` for all).
    func cacheDir(for remoteID: UUID) -> URL {
        cacheRoot.appendingPathComponent(remoteID.uuidString, isDirectory: true)
    }

    /// Key file path saved for a `.keyFile` SFTP remote (a path, not a secret), so edit
    /// forms can show it instead of asking for it again.
    public func storedKeyFilePath(for remoteID: UUID) -> String? {
        (try? keychain.get(remoteID: remoteID, kind: .privateKey)) ?? nil
    }

    /// Secrets typed in the Add/Edit form, not yet saved. Blank values fall back to what the
    /// Keychain already holds (editing "leave blank to keep").
    public struct DraftSecrets {
        public var sftp: SFTPSecrets?
        public var s3: S3Secrets?
        public var ftp: FTPSecrets?
        public var options: [String: String]

        public init(sftp: SFTPSecrets? = nil, s3: S3Secrets? = nil, ftp: FTPSecrets? = nil, options: [String: String] = [:]) {
            self.sftp = sftp
            self.s3 = s3
            self.ftp = ftp
            self.options = options
        }
    }

    struct PreparedRclone {
        let configText: String
        let envOverrides: [String: String]
        let remotePath: String
        /// Decrypted generated key on disk; the caller removes it when done.
        let ephemeralKeyURL: URL?
    }

    /// Turns a remote and its secrets (from `draft` first, then the Keychain) into rclone
    /// config text, environment overrides and the path to serve. Shared by mount and
    /// "Test connection" so both exercise exactly the same inputs.
    private func prepareRclone(for remote: Remote, draft: DraftSecrets?) async throws -> PreparedRclone {
        let rcloneBinary = self.rcloneBinary
        var ephemeralKeyURL: URL? = nil
        var envOverrides: [String: String] = [:]
        var bundle = BackendSecrets()
        let remotePath: String

        func stored(_ kind: SecretKind, draft value: String? = nil) throws -> String? {
            if let value, !value.isEmpty { return value }
            return try keychain.get(remoteID: remote.id, kind: kind)
        }

        do {
            switch remote.backend {
            case .sftp(let sftp):
                let d = draft?.sftp
                let password = try stored(.password, draft: d?.password)
                var resolvedKeyPath: String? = nil
                switch sftp.authKind {
                case .password: break
                case .keyFile:
                    resolvedKeyPath = try stored(.privateKey, draft: d?.privateKeyPath)
                case .generatedKey:
                    if let pem = try stored(.privateKey, draft: d?.privateKeyPath) {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent(TempNaming.keyName(remoteID: remote.id))
                        try pem.write(to: url, atomically: true, encoding: .utf8)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                        ephemeralKeyURL = url
                        resolvedKeyPath = url.path
                    }
                }
                bundle.sftp = SFTPSecrets(
                    password: password,
                    privateKeyPath: resolvedKeyPath,
                    keyPassphrase: try stored(.keyPassphrase, draft: d?.keyPassphrase)
                )
                if sftp.authKind == .keyFile, let pp = bundle.sftp?.keyPassphrase, !pp.isEmpty {
                    // Without this, passphrase-protected keys fail with
                    // "ssh: this private key is passphrase protected".
                    envOverrides[RcloneConfigBuilder.keyPassphraseEnvVar] =
                        try await Self.offMain { try RcloneProcess.obscure(plaintext: pp, binary: rcloneBinary) }
                }
                if sftp.authKind == .password, let p = password {
                    envOverrides[RcloneConfigBuilder.passwordEnvVar(remoteID: remote.id)] =
                        try await Self.offMain { try RcloneProcess.obscure(plaintext: p, binary: rcloneBinary) }
                }
                if let verifier = hostKeyVerifier {
                    let host = sftp.host, port = sftp.port
                    let inspection = try await Self.offMain { try verifier.inspect(host: host, port: port) }
                    try verifier.resolve(inspection)     // dialog + known_hosts on the main actor
                } else if !allowMissingHostKeyVerifier {
                    // Never run SFTP without known_hosts checking.
                    throw HostKeyError.verifierUnavailable
                }
                remotePath = sftp.remotePath

            case .s3(let s3):
                guard let access = try stored(.s3AccessKeyID, draft: draft?.s3?.accessKeyID),
                      let secret = try stored(.s3SecretAccessKey, draft: draft?.s3?.secretAccessKey) else {
                    throw RcloneConfigError.missingS3Credentials
                }
                bundle.s3 = S3Secrets(accessKeyID: access, secretAccessKey: secret)
                envOverrides[RcloneConfigBuilder.s3SecretEnvVar(remoteID: remote.id)] = secret
                remotePath = s3.prefix.isEmpty ? s3.bucket : "\(s3.bucket)/\(s3.prefix)"

            case .ftp(let ftp):
                guard let password = try stored(.password, draft: draft?.ftp?.password) else {
                    throw RcloneConfigError.missingFTPPassword
                }
                bundle.ftp = FTPSecrets(password: password)
                envOverrides[RcloneConfigBuilder.passwordEnvVar(remoteID: remote.id)] =
                    try await Self.offMain { try RcloneProcess.obscure(plaintext: password, binary: rcloneBinary) }
                remotePath = ftp.remotePath

            case .rclone(let cfg):
                for opt in cfg.secretOptions {
                    guard let value = try stored(.option(opt.name), draft: draft?.options[opt.name]), !value.isEmpty else {
                        if opt.required { throw RcloneConfigError.missingSecret(opt.name) }
                        continue
                    }
                    bundle.options[opt.name] = value
                    var envValue = value
                    if opt.obscure {
                        envValue = try await Self.offMain { try RcloneProcess.obscure(plaintext: value, binary: rcloneBinary) }
                    }
                    envOverrides[RcloneConfigBuilder.optionEnvVar(opt.name)] = envValue
                }
                remotePath = cfg.remotePath
            }

            let configText = try RcloneConfigBuilder.build(
                remote: remote,
                secrets: bundle,
                knownHostsPath: hostKeyVerifier?.knownHostsPath
            )
            return PreparedRclone(configText: configText, envOverrides: envOverrides,
                                  remotePath: remotePath, ephemeralKeyURL: ephemeralKeyURL)
        } catch {
            if let url = ephemeralKeyURL { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// "Test connection": lists the remote with the form's (unsaved) values and reports a
    /// readable result. Nothing is stored or mounted.
    public func testConnection(_ remote: Remote, draft: DraftSecrets = DraftSecrets()) async -> ConnectionTestResult {
        let binary = rcloneBinary
        do {
            let prepared = try await prepareRclone(for: remote, draft: draft)
            defer { if let url = prepared.ephemeralKeyURL { try? FileManager.default.removeItem(at: url) } }
            return try await Self.offMain {
                ConnectionTester.run(binary: binary, configText: prepared.configText,
                                     remotePath: prepared.remotePath, env: prepared.envOverrides)
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return .failure(reason)
        }
    }

    public struct ImportSummary: Equatable {
        public struct Skipped: Equatable {
            public let name: String
            public let reason: String
        }
        public var imported: [String] = []
        public var skipped: [Skipped] = []
    }

    /// Adds remotes read from an rclone.conf. Obscured passwords are revealed with rclone and
    /// stored in the Keychain only. `buckets` supplies the bucket for S3 sections (rclone.conf
    /// has none). Sections that cannot be converted are reported, never silently dropped.
    public func importRemotes(
        _ sections: [RcloneConfSection],
        defaultProtocol: MountProtocol,
        buckets: [String: String] = [:],
        sharePaths: [String: String] = [:]
    ) async -> ImportSummary {
        let binary = rcloneBinary
        var summary = ImportSummary()
        for section in sections {
            let outcome: ImportOutcome
            do {
                outcome = try await Self.offMain {
                    RcloneConfImporter.convert(section, defaultProtocol: defaultProtocol,
                                               reveal: { try RcloneProcess.reveal(obscured: $0, binary: binary) })
                }
            } catch {
                outcome = .unsupported("Import failed unexpectedly")
            }
            switch outcome {
            case .unsupported(let reason):
                summary.skipped.append(.init(name: section.name, reason: reason))
            case .ready(var imported):
                if imported.needsBucket {
                    imported.setBucket(buckets[section.name] ?? "")
                    if imported.needsBucket {
                        summary.skipped.append(.init(name: section.name, reason: "A bucket name is required"))
                        continue
                    }
                }
                if imported.needsRemotePath {
                    imported.setSharePath(sharePaths[section.name] ?? "")
                    if imported.needsRemotePath {
                        summary.skipped.append(.init(name: section.name, reason: "A share name is required"))
                        continue
                    }
                }
                imported.remote.name = RcloneConfImporter.uniqueName(
                    RemoteName.pathComponent(from: section.name), existing: sessions.map { $0.remote.name })
                do {
                    try add(imported.remote, sftpSecrets: imported.sftp, s3Secrets: imported.s3,
                            ftpSecrets: imported.ftp, optionSecrets: imported.options.isEmpty ? nil : imported.options)
                    summary.imported.append(imported.remote.name)
                } catch {
                    summary.skipped.append(.init(name: section.name, reason: "\(error)"))
                }
            }
        }
        return summary
    }

    /// What one mount attempt has created so far, so a cancel (delete, quit, user) can undo it
    /// even while an off-main NetFS / `mount_nfs` call is still running.
    @MainActor
    final class MountAttempt {
        var task: Task<Void, Error>?
        var process: Process?
        var configURL: URL?
        var ephemeralKeyURL: URL?
        var mountpoint: String?
        var cancelled = false
    }

    private(set) var mountAttempts: [UUID: MountAttempt] = [:]

    /// True while a mount for this remote is starting (cancellable).
    public func isMountInFlight(remoteID: UUID) -> Bool { mountAttempts[remoteID] != nil }

    /// Cancels a mount that is still starting: stops the rclone it spawned and unmounts
    /// anything it already mounted. The session returns to idle.
    public func cancelMount(remoteID: UUID) {
        guard let attempt = mountAttempts[remoteID] else { return }
        abort(attempt, unmountBlocking: false)
    }

    /// Marks the attempt cancelled and tears down what exists now, synchronously. The
    /// attempt's own task re-checks after each await and finishes any remaining cleanup.
    private func abort(_ attempt: MountAttempt, unmountBlocking blocking: Bool) {
        attempt.cancelled = true
        attempt.task?.cancel()
        if let proc = attempt.process, proc.isRunning { proc.terminate() }
        if blocking, let mp = attempt.mountpoint {
            try? mounter.unmount(mountpoint: mp)
            attempt.mountpoint = nil
        }
    }

    /// Mounts a remote. Everything that blocks (rclone start-up, host-key scan, NetFS,
    /// mount_nfs) runs off the main thread; only state changes and dialogs use it. The work
    /// runs as a task tracked per remote so `cancelMount`, `delete` and `shutdownAll` can stop it.
    public func mount(remoteID: UUID) async throws {
        guard let session = sessions.first(where: { $0.id == remoteID }) else { return }
        switch session.status {
        case .starting, .stopping, .mounted: return    // an operation is already in flight
        default: break
        }
        session.transition(to: .starting)
        let attempt = MountAttempt()
        mountAttempts[remoteID] = attempt
        // Unstructured on purpose: cancelling the caller (e.g. a superseded retry task) must
        // not abort a mount that is already in flight.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.mountAttempts[remoteID] === attempt { self.mountAttempts[remoteID] = nil } }
            try await self.performMount(session: session, attempt: attempt)
        }
        attempt.task = task
        try await task.value
    }

    /// Still wanted: not cancelled, and the session is still in the list.
    private func isWanted(_ session: RemoteSession, _ attempt: MountAttempt) -> Bool {
        !attempt.cancelled && !Task.isCancelled && sessions.contains(where: { $0 === session })
    }

    private func performMount(session: RemoteSession, attempt: MountAttempt) async throws {
        let remoteID = session.id
        let mounter = self.mounter
        let rcloneBinary = self.rcloneBinary

        let remote = session.remote
        let logFile = logsDir.appendingPathComponent("\(remote.id.uuidString).log")

        /// Undoes whatever the attempt created. Safe to call twice.
        func rollback() async {
            if let proc = attempt.process, proc.isRunning { proc.terminate() }
            if let url = attempt.ephemeralKeyURL { try? FileManager.default.removeItem(at: url) }
            if let cfg = attempt.configURL { try? FileManager.default.removeItem(at: cfg.deletingLastPathComponent()) }
            attempt.ephemeralKeyURL = nil
            attempt.configURL = nil
            if let mp = attempt.mountpoint {
                attempt.mountpoint = nil
                _ = try? await Self.offMain { try mounter.unmount(mountpoint: mp) }
            }
        }
        /// Cancelled: roll back and leave the session idle (or gone) without an error.
        func finishCancelled() async {
            stopUploadMonitor(remoteID: remoteID)
            await rollback()
            if sessions.contains(where: { $0 === session }), case .starting = session.status {
                session.transition(to: .idle)
            }
        }

        do {
            let prepared = try await prepareRclone(for: remote, draft: nil)
            attempt.ephemeralKeyURL = prepared.ephemeralKeyURL
            guard isWanted(session, attempt) else { return await finishCancelled() }
            let configText = prepared.configText
            let envOverrides = prepared.envOverrides
            let remotePath = prepared.remotePath
            let logURL = logsDir.appendingPathComponent("\(remote.id.uuidString).log")
            let tuning = remote.effectiveTuning
            let extraArgs = MountOptions.serveArgs(readOnly: remote.readOnly, bandwidthLimit: remote.bandwidthLimit)
                + cacheArgs(for: remote, remotePath: remotePath)
            let runner = RcloneProcess(binary: rcloneBinary, logFile: logURL)
            let volname = mounter.volumeName(from: remote.name)
            let spawned: RcloneProcess.Spawned
            switch remote.mountProtocol {
            case .webdav:
                spawned = try runner.spawnWebDAVServe(
                    remoteName: RcloneConfigBuilder.sectionName,
                    remotePath: remotePath,
                    configText: configText,
                    baseurl: "/\(volname)",
                    liveUpdates: remote.liveUpdates,
                    tuning: tuning,
                    envOverrides: envOverrides,
                    extraArgs: extraArgs
                )
            case .nfs:
                spawned = try runner.spawnNFSServe(
                    remoteName: RcloneConfigBuilder.sectionName,
                    remotePath: remotePath,
                    configText: configText,
                    liveUpdates: remote.liveUpdates,
                    tuning: tuning,
                    envOverrides: envOverrides,
                    extraArgs: extraArgs
                )
            }
            attempt.process = spawned.process
            attempt.configURL = spawned.configURL
            // Attached right after spawning so an exit at any later point is seen. While the
            // session is still starting handleRcloneExit ignores it and the isRunning check
            // below fails the mount; once mounted it drops the mount.
            let watched = spawned.process
            watched.terminationHandler = { [weak self, weak session] _ in
                // Bind strong locals first: older compilers reject using the captured weak
                // vars inside the concurrently-executing Task.
                guard let manager = self, let exited = session else { return }
                Task { @MainActor in
                    await manager.handleRcloneExit(session: exited, process: watched)
                }
            }
            guard isWanted(session, attempt) else { return await finishCancelled() }
            try await waitForPort(spawned.port, process: spawned.process, timeout: portWaitTimeout)
            guard isWanted(session, attempt) else { return await finishCancelled() }

            let mountpoint: String
            switch remote.mountProtocol {
            case .webdav:
                let (port, user, pass) = (spawned.port, spawned.user, spawned.password)
                mountpoint = try await Self.offMain {
                    try mounter.mountWebDAV(host: "127.0.0.1", port: port, baseurl: "/\(volname)", user: user, password: pass)
                }
            case .nfs:
                let (port, name) = (spawned.port, remote.name)
                mountpoint = try await Self.offMain {
                    let mp = try mounter.resolveMountpoint(name: name)
                    try mounter.mountNFS(host: "127.0.0.1", port: port, exportPath: "/", name: name, mountpoint: mp)
                    return mp
                }
            }
            attempt.mountpoint = mountpoint
            guard isWanted(session, attempt) else { return await finishCancelled() }
            guard watched.isRunning else {
                throw NSError(domain: "rmount", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "rclone exited before the mount completed (exit \(watched.terminationStatus))"])
            }

            session.rcloneProcess = spawned.process
            session.mountpoint = mountpoint
            session.ephemeralKeyURL = attempt.ephemeralKeyURL
            session.rcloneConfigURL = spawned.configURL
            session.transition(to: .mounted(at: mountpoint))
            startUploadMonitor(remoteID: remoteID, client: controlClient(spawned))
        } catch {
            if attempt.cancelled || !sessions.contains(where: { $0 === session }) {
                return await finishCancelled()
            }
            stopUploadMonitor(remoteID: remoteID)
            // rclone's own explanation (bad key, auth failure, ...) only goes to its log, and
            // only if rclone was started in this attempt (else the log is the previous run's).
            let reason = Self.failureReason(error, logFile: attempt.process != nil ? logFile : nil)
            await rollback()
            session.transition(to: .failed(reason: reason))
            throw error
        }
    }

    /// Unmounts a remote without blocking the main thread. Throws `Mounter.MountError.busy`
    /// (session left mounted) when the volume is in use; call again with `force: true` once
    /// the user agrees.
    public func unmount(remoteID: UUID, force: Bool = false) async throws {
        guard let session = sessions.first(where: { $0.id == remoteID }) else { return }
        switch session.status {
        case .starting, .stopping: return
        default: break
        }
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = nil
        let previous = session.status
        session.transition(to: .stopping)
        if let mp = session.mountpoint {
            let mounter = self.mounter
            do { try await Self.offMain { try mounter.unmount(mountpoint: mp, force: force) } }
            catch {
                session.transition(to: previous)    // still mounted (e.g. busy)
                throw error
            }
        }
        finishUnmount(session)
    }

    /// Synchronous variant for app quit and remote deletion, where there is no run loop
    /// left to wait on.
    public func unmountBlocking(remoteID: UUID) throws {
        guard let session = sessions.first(where: { $0.id == remoteID }) else { return }
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = nil
        if let mp = session.mountpoint {
            try mounter.unmount(mountpoint: mp, force: true)
        }
        finishUnmount(session)
    }

    private func finishUnmount(_ session: RemoteSession) {
        stopUploadMonitor(remoteID: session.id)
        let proc = session.rcloneProcess
        session.rcloneProcess = nil          // so the exit watcher sees this was intentional
        if let proc, proc.isRunning {
            proc.terminate()
        }
        if let url = session.ephemeralKeyURL {
            try? FileManager.default.removeItem(at: url)
        }
        persistRefreshedSecrets(session)
        session.rcloneProcess = nil
        session.mountpoint = nil
        session.ephemeralKeyURL = nil
        session.rcloneConfigURL = nil
        session.transition(to: .idle)
    }

    /// rclone rewrites its config when it refreshes an OAuth token. The config is a throw-away
    /// temp file, so copy refreshed values (options marked `refreshable`) back into the
    /// Keychain before deleting it; otherwise providers that rotate refresh tokens break.
    private func persistRefreshedSecrets(_ session: RemoteSession) {
        guard let url = session.rcloneConfigURL else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard case .rclone(let cfg) = session.remote.backend,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for opt in cfg.secretOptions where opt.refreshable {
            guard let fresh = RcloneConfigReader.value(of: opt.name, in: text), !fresh.isEmpty else { continue }
            let old = (try? keychain.get(remoteID: session.id, kind: .option(opt.name))) ?? nil
            if fresh != old {
                try? keychain.set(remoteID: session.id, kind: .option(opt.name), value: fresh)
            }
        }
    }

    /// rclone exited while its remote was still marked mounted (killed, crashed, machine
    /// slept through a connection drop). The mount it served is now dead and macOS would
    /// pop up "Server connections interrupted", so drop it, record why, and retry if the
    /// remote is set to auto-mount.
    func handleRcloneExit(session: RemoteSession, process: Process) async {
        // Intentional unmount/shutdown detach the process first; anything else is a surprise.
        guard session.rcloneProcess === process, case .mounted = session.status else { return }
        stopUploadMonitor(remoteID: session.id)
        let status = process.terminationStatus
        let mountpoint = session.mountpoint
        session.rcloneProcess = nil
        if let mp = mountpoint {
            let mounter = self.mounter
            _ = try? await Self.offMain { try mounter.forceUnmount(mountpoint: mp) }
        }
        if let url = session.ephemeralKeyURL { try? FileManager.default.removeItem(at: url) }
        // rclone is gone, so its config is final: keep a refreshed token, then delete the temp dir.
        persistRefreshedSecrets(session)
        session.mountpoint = nil
        session.ephemeralKeyURL = nil
        session.rcloneConfigURL = nil
        var reason = "rclone stopped unexpectedly (exit \(status)); the mount was removed"
        if let tail = Self.logTail(of: logsDir.appendingPathComponent("\(session.id.uuidString).log")) {
            reason += "\n" + tail
        }
        session.transition(to: .failed(reason: reason))
        if session.remote.autoMount { scheduleMount(remoteID: session.id, attempt: 0) }
    }

    /// Plain argv of all running processes (no environment, so no secrets), or "" on failure.
    public nonisolated static func liveProcessCommandLines() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // ends when ps exits
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes `rmount-rclone-*` dirs and `rmount-key-*` files left in the temp dir by a crash or
    /// force-quit (they hold a plaintext config or a decrypted key). Call once at launch.
    /// Only items carrying this app's tag (bundle id) are considered, so another flavor or
    /// instance is never touched. Legacy untagged items (older builds) are removed only when
    /// older than `legacyMinAge` and absent from the process argv. Items used by a session
    /// here, or modified in the last `minAge` seconds, are always kept.
    @discardableResult
    public func sweepStaleTempItems(
        in dir: URL = FileManager.default.temporaryDirectory,
        tag: String = TempNaming.tag,
        minAge: TimeInterval = 60,
        legacyMinAge: TimeInterval = 24 * 3600,
        now: Date = Date(),
        processLister: () -> String = SessionManager.liveProcessCommandLines
    ) -> Int {
        var keep = Set<String>()
        for s in sessions {
            if let c = s.rcloneConfigURL { keep.insert(c.deletingLastPathComponent().lastPathComponent) }
            if let k = s.ephemeralKeyURL { keep.insert(k.lastPathComponent) }
        }
        let fm = FileManager.default
        let own = [TempNaming.rclonePrefix + tag + "-", TempNaming.keyPrefix + tag + "-"]
        let legacy = [TempNaming.rclonePrefix, TempNaming.keyPrefix]
        var live: String?
        var removed = 0
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(name) {
            let isOwn = own.contains { name.hasPrefix($0) }
            let isLegacy = !isOwn && legacy.contains { prefix in
                name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            }
            guard isOwn || isLegacy else { continue }
            let url = dir.appendingPathComponent(name)
            let age = ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
                .map { now.timeIntervalSince($0) } ?? .infinity
            if age < (isLegacy ? max(minAge, legacyMinAge) : minAge) { continue }
            if isLegacy {
                if live == nil { live = processLister() }
                if live!.contains(name) { continue }
            }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Unmounts every mounted remote at app quit. The unmounts run in parallel and the whole
    /// call is bounded by `deadline` seconds, so one hung `diskutil` cannot stall quitting.
    public func shutdownAll(deadline: TimeInterval = 8) {
        for (_, task) in retryTasks { task.cancel() }
        retryTasks.removeAll()
        for attempt in Array(mountAttempts.values) { abort(attempt, unmountBlocking: true) }
        // Invalidate every callback before unmounting: even a busy volume must not
        // republish Finder progress while the app is quitting.
        for remoteID in Array(uploadMonitors.keys) { stopUploadMonitor(remoteID: remoteID) }
        finderProgressPublisher.clearAll()
        finderBadgeTracker.clearAll()
        let targets = sessions.compactMap { s -> (RemoteSession, String)? in
            if case .mounted = s.status, let mp = s.mountpoint { return (s, mp) }
            return nil
        }
        let mounter = self.mounter
        let group = DispatchGroup()
        let failed = NSLock()
        var failedIDs = Set<UUID>()
        for (session, mp) in targets {
            let id = session.id
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                do { try mounter.unmount(mountpoint: mp) }
                catch { failed.lock(); failedIDs.insert(id); failed.unlock() }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + deadline)
        failed.lock(); let failedNow = failedIDs; failed.unlock()
        // A failed (busy) unmount keeps its session as it was; a hung one is abandoned.
        for (session, _) in targets where !failedNow.contains(session.id) {
            finishUnmount(session)
        }
    }

    public func logURL(for remoteID: UUID) -> URL {
        logsDir.appendingPathComponent("\(remoteID.uuidString).log")
    }

    /// The error text, with the log tail appended when `logFile` is given (rclone ran this attempt).
    static func failureReason(_ error: Error, logFile: URL?) -> String {
        var reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        if let logFile, let tail = logTail(of: logFile) { reason += "\n" + tail }
        return reason
    }

    /// Last `lines` non-empty lines of an rclone log, or nil if it is missing/empty.
    static func logTail(of url: URL, lines: Int = 3) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let tail = text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(lines)
        return tail.isEmpty ? nil : tail.joined(separator: "\n")
    }

    private func waitForPort(_ port: Int, process: Process, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.canConnect(port: port) { return }
            if !process.isRunning {
                throw NSError(domain: "rmount", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "rclone exited before it started listening (exit \(process.terminationStatus))"])
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "rmount", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "rclone serve did not open port \(port) within \(Int(timeout))s"])
    }

    /// One non-blocking-in-practice TCP connect to 127.0.0.1 (refused or accepted at once).
    nonisolated static func canConnect(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
