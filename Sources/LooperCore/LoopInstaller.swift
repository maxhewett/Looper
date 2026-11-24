import Foundation

/// Counts returned to the CLI and menu bar UI after an install pass.
public struct InstallSummary: Sendable {
    public var installed: [LoopPackage] = []
    public var skipped: [LoopPackage] = []
    public var failed: [(LoopPackage, Error)] = []
    public var stopped = false
    public var stopReason: String?

    public var requiresAttention = false

    public var outcome: String {
        if let stopReason { return stopReason }
        var text = "Finished: \(installed.count) installed, \(skipped.count) skipped, \(failed.count) failed."
        if let (package, error) = failed.last {
            text += " " + Self.failureDetail(package, error)
        }
        return text
    }

    static func failureDetail(_ package: LoopPackage, _ error: Error) -> String {
        if let network = error as? URLError {
            return "\(package.displayName) · \(package.url.host ?? "Download server") · \(network.localizedDescription) (\(network.errorCode))"
        }
        return "\(package.displayName) · \(error.localizedDescription)"
    }

    public var storageWasInsufficient: Bool {
        stopReason?.localizedCaseInsensitiveContains("storage") == true
    }
}

/// Coordinates manifest items through download, verification, package install,
/// and state persistence.
///
/// The actor boundary keeps future UI-triggered runs from mutating the same
/// cache/state files at the same time.
public actor LoopInstaller {
    private let paths: LooperPaths
    private let downloader: ResumableDownloader
    private let installer: PackageInstaller
    private let musicAppsStore: MusicAppsContentStore
    private let stateStore: StateStore
    private let eventStore: LooperEventStore?
    private let requestID: String?

    public init(
        paths: LooperPaths = LooperPaths(),
        downloader: ResumableDownloader = ResumableDownloader(),
        installer: PackageInstaller = PackageInstaller(),
        musicAppsStore: MusicAppsContentStore = MusicAppsContentStore(),
        eventStore: LooperEventStore? = nil,
        requestID: String? = nil
    ) {
        self.paths = paths
        self.downloader = downloader
        self.installer = installer
        self.musicAppsStore = musicAppsStore
        self.stateStore = StateStore(url: paths.stateFile)
        self.eventStore = eventStore
        self.requestID = requestID
    }

    public func install(manifest: LoopManifest) async throws -> InstallSummary {
        try await install(manifest: manifest, policy: .all)
    }

    public func install(manifest: LoopManifest, policy: LooperPolicy) async throws -> InstallSummary {
        let state = try stateStore.load()
        let plan = ReconcilePlanner.build(
            provider: StaticManifestProvider(manifest: manifest),
            policy: policy,
            existingState: state
        )
        return try await install(plan: plan, initialState: state)
    }

    public func reconcile(provider: ContentProvider = AppleAudioPackageProvider(), policy: LooperPolicy = .all) async throws -> InstallSummary {
        let state = try stateStore.load()
        try paths.prepare()
        if policy.dryRun {
            let plan = ReconcilePlanner.build(provider: provider, policy: policy, existingState: state)
            return dryRunSummary(for: plan)
        }
        var planningState = state
        planningState.currentRun = InstallRunState(
            isRunning: true,
            startedAt: Date(),
            message: "Planning \(provider.displayName) run...",
            completedPackages: 0,
            totalPackages: 0
        )
        try? stateStore.save(planningState)
        let plan = ReconcilePlanner.build(provider: provider, policy: policy, existingState: state)
        return try await install(plan: plan, initialState: state)
    }

    public func plan(provider: ContentProvider = AppleAudioPackageProvider(), policy: LooperPolicy = .all) throws -> ReconcilePlan {
        let state = try stateStore.load()
        return ReconcilePlanner.build(provider: provider, policy: policy, existingState: state)
    }

    public func install(plan: ReconcilePlan) async throws -> InstallSummary {
        try await install(plan: plan, initialState: stateStore.load())
    }

    private func install(plan: ReconcilePlan, initialState: InstallState) async throws -> InstallSummary {
        if plan.policy.dryRun {
            return dryRunSummary(for: plan)
        }

        try paths.prepare()

        let installEntries = plan.entries.filter { $0.action == .install }
        let skipCount = plan.entries.count - installEntries.count
        var state = initialState
        for entry in plan.entries where entry.action == .skip {
            state.failedPackages.removeValue(forKey: entry.id)
        }
        state.lastCheck = Date()
        state.currentRun = InstallRunState(
            isRunning: true,
            startedAt: Date(),
            message: "Planning \(plan.providerName) run...",
            completedPackages: 0,
            totalPackages: installEntries.count
        )
        try stateStore.save(state)

        var summary = InstallSummary()
        var completedPackages = 0

        let storagePreflight = DiskSpaceChecker.preflightRun(
            paths: paths,
            packages: installEntries.map(\.package)
        )
        appendEvent(
            level: storagePreflightEventLevel(storagePreflight),
            category: "Planning",
            message: storagePreflight.shouldStop ? "Run blocked by storage preflight." : "Run plan prepared.",
            detail: "\(installEntries.count) to install, \(skipCount) already present or outside scope. \(storagePreflight.detail)"
        )

        defer {
            var finalState = (try? stateStore.load()) ?? state
            finalState.currentRun?.needsAttention = !summary.failed.isEmpty || summary.requiresAttention
            finalState.currentRun?.isRunning = false
            finalState.currentRun?.finishedAt = Date()
            finalState.currentRun?.currentPackageID = nil
            finalState.currentRun?.currentPackageName = nil
            finalState.currentRun?.receivedBytes = nil
            finalState.currentRun?.expectedBytes = nil
            finalState.currentRun?.message = summary.outcome
            finalState.currentRun?.updatedAt = Date()
            try? stateStore.save(finalState)
            try? PendingRequestStore.clearStopRequests(in: paths.requestDirectory)
        }

        if let id = plan.policy.requestedPackageID, plan.entries.isEmpty {
            summary.stopped = true
            summary.requiresAttention = true
            summary.stopReason = "Package \(id) is unavailable in the current catalogue or excluded by managed policy."
            appendEvent(level: .error, category: "Planning", message: summary.outcome, packageIdentifier: id)
            return summary
        }

        if storagePreflight.shouldStop {
            summary.requiresAttention = true
            summary.stopped = true
            summary.stopReason = "\(storagePreflight.message) \(storagePreflight.detail)"
            state.currentRun?.message = storagePreflight.message
            state.currentRun?.updatedAt = Date()
            try stateStore.save(state)
            return summary
        }

        var lastUnreachableHost: String?
        for entry in plan.entries {
            let package = entry.package

            if stopRequested() {
                summary.stopped = true
                summary.stopReason = "Run stopped by request."
                state.currentRun?.message = "Stopping after current package boundary."
                state.currentRun?.updatedAt = Date()
                try? stateStore.save(state)
                appendEvent(
                    level: .warning,
                    category: "Run",
                    message: "Run stop requested.",
                    detail: "\(completedPackages)/\(installEntries.count) loops completed before stopping."
                )
                break
            }

            if entry.action == .skip {
                summary.skipped.append(package)
                continue
            }

            if plan.policy.dryRun {
                summary.skipped.append(package)
                continue
            }

            var phase = "Download"
            do {
                let cachedPackage = paths.packageCacheFile(for: package)
                let partialFile = paths.partialDownloadFile(for: package)
                let packageStoragePreflight = DiskSpaceChecker.preflightPackage(paths: paths, package: package)
                if packageStoragePreflight.shouldStop {
                    throw LooperError.insufficientStorage(packageStoragePreflight.detail)
                }
                state.currentRun?.currentPackageID = package.id
                state.currentRun?.currentPackageName = package.displayName
                state.currentRun?.message = "Downloading \(package.displayName)..."
                state.currentRun?.completedPackages = completedPackages
                state.currentRun?.receivedBytes = nil
                state.currentRun?.expectedBytes = nil
                state.currentRun?.updatedAt = Date()
                try? stateStore.save(state)
                appendEvent(
                    level: .info,
                    category: "Download",
                    message: state.failedPackages[package.id] == nil ? "Downloading \(package.displayName)." : "Retrying \(package.displayName).",
                    packageIdentifier: package.pkgIdentifier ?? package.id
                )

                let transfer = try await downloader.download(package: package, to: cachedPackage, partialFile: partialFile) { progress in
                    do {
                        var progressState = try self.stateStore.load()
                        progressState.currentRun?.currentPackageID = progress.package.id
                        progressState.currentRun?.currentPackageName = progress.package.displayName
                        progressState.currentRun?.message = "Downloading \(progress.package.displayName)..."
                        progressState.currentRun?.receivedBytes = progress.receivedBytes
                        progressState.currentRun?.expectedBytes = progress.expectedBytes
                        progressState.currentRun?.updatedAt = Date()
                        try self.stateStore.save(progressState)
                    } catch {
                        // Progress is best-effort; install correctness does not
                        // depend on every UI update making it to disk.
                    }
                }
                state.transferTotals[transfer.source.rawValue, default: TransferTotals()].bytes += transfer.bytes
                lastUnreachableHost = nil
                appendEvent(
                    level: .debug,
                    category: "Download",
                    message: "Downloaded \(package.displayName).",
                    packageIdentifier: package.pkgIdentifier ?? package.id
                )

                phase = "Install"
                state.currentRun?.message = "Installing \(package.displayName)..."
                state.currentRun?.receivedBytes = nil
                state.currentRun?.expectedBytes = nil
                state.currentRun?.updatedAt = Date()
                try? stateStore.save(state)
                appendEvent(
                    level: .info,
                    category: "Install",
                    message: "Installing \(package.displayName).",
                    packageIdentifier: package.pkgIdentifier ?? package.id
                )
                try install(cachedPackage: cachedPackage, package: package)

                // Save after each successful package so a later failure does not
                // force the next run to redo already installed work.
                state.installedPackages[package.id] = InstalledPackage(
                    displayName: package.displayName,
                    installedAt: Date(),
                    pkgIdentifier: package.pkgIdentifier
                )
                state.transferTotals[transfer.source.rawValue, default: TransferTotals()].installs += 1
                state.failedPackages[package.id] = nil
                state.removedPackages[package.id] = nil
                if let receipt = package.pkgIdentifier {
                    state.removedPackages = state.removedPackages.filter { $0.value.pkgIdentifier != receipt }
                }
                summary.installed.append(package)
                completedPackages += 1
                state.currentRun?.completedPackages = completedPackages
                state.currentRun?.message = "Installed \(package.displayName)."
                state.currentRun?.updatedAt = Date()
                try stateStore.save(state)
                appendEvent(
                    level: .success,
                    category: "Install",
                    message: "Installed \(package.displayName).",
                    detail: "\(completedPackages)/\(installEntries.count) loops complete.",
                    packageIdentifier: package.pkgIdentifier ?? package.id
                )
            } catch {
                // Keep going after a package fails. A lab run should install
                // everything it can and leave clear state for the failed items.
                state.failedPackages[package.id] = FailedPackage(
                    displayName: package.displayName,
                    failedAt: Date(),
                    message: InstallSummary.failureDetail(package, error)
                )
                summary.failed.append((package, error))
                completedPackages += 1
                state.currentRun?.completedPackages = completedPackages
                state.currentRun?.message = "Failed \(package.displayName)."
                state.currentRun?.updatedAt = Date()
                try? stateStore.save(state)
                appendEvent(
                    level: .error,
                    category: phase,
                    message: "Failed \(package.displayName).",
                    detail: InstallSummary.failureDetail(package, error),
                    packageIdentifier: package.pkgIdentifier ?? package.id
                )
                if DiskSpaceChecker.isOutOfSpace(error) {
                    summary.stopped = true
                    summary.requiresAttention = true
                    summary.stopReason = "Run stopped for insufficient storage while processing \(package.displayName). \(error.localizedDescription)"
                    break
                }
                if let networkError = error as? URLError,
                   [.timedOut, .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet].contains(networkError.code),
                   let host = package.url.host {
                    if lastUnreachableHost == host {
                        summary.stopped = true
                        summary.stopReason = "Could not reach \(host) for two consecutive downloads. Check the network connection and run again."
                        break
                    }
                    lastUnreachableHost = host
                } else {
                    lastUnreachableHost = nil
                }
            }
        }

        appendEvent(
            level: summary.stopped ? .warning : (summary.failed.isEmpty ? .success : .warning),
            category: "Run",
            message: summary.stopped ? "Run stopped." : "Run completed.",
            detail: "\(summary.installed.count) installed, \(summary.skipped.count) skipped, \(summary.failed.count) failed."
        )
        try stateStore.save(state)
        return summary
    }

    /// Read status for the menu bar and `looper status`.
    ///
    /// Status checks are intentionally read-only. The app may be launched by a
    /// normal user who can inspect `/Library` state but cannot create Looper's
    /// system-wide support folders.
    public func state() throws -> InstallState {
        return try stateStore.load()
    }

    /// Summarise a plan without touching system state or cache directories.
    ///
    /// This keeps preview commands useful for standard users while reserving
    /// writes to `/Library` for the approved helper or an MDM-driven run.
    private func dryRunSummary(for plan: ReconcilePlan) -> InstallSummary {
        var summary = InstallSummary()
        for entry in plan.entries {
            switch entry.action {
            case .install, .skip:
                summary.skipped.append(entry.package)
            }
        }
        return summary
    }

    private func appendEvent(
        level: LooperEvent.Level,
        category: String,
        message: String,
        detail: String? = nil,
        packageIdentifier: String? = nil
    ) {
        eventStore?.append(LooperEvent(
            level: level,
            category: category,
            message: message,
            detail: detail,
            packageIdentifier: packageIdentifier,
            requestID: requestID
        ))
    }

    private func stopRequested() -> Bool {
        PendingRequestStore.loadAll(in: paths.requestDirectory).stopRequestedAt != nil
    }

    private func storagePreflightEventLevel(_ preflight: DiskSpacePreflight) -> LooperEvent.Level {
        switch preflight.level {
        case .ok: return .info
        case .warning: return .warning
        case .failure: return .error
        }
    }

    private func install(cachedPackage: URL, package: LoopPackage) throws {
        switch package.installFormat {
        case .installerPackage:
            try installer.install(pkg: cachedPackage)
            if let receipt = package.pkgIdentifier,
               !installer.receiptVersionSatisfiesCatalogue(identifier: receipt, catalogueVersion: package.packageVersion) {
                throw LooperError.installFailed(status: 1, message: "The installer finished but the receipt does not confirm the catalogue version for \(package.displayName).")
            }
            if let path = package.normalisedFileCheckPath, !FileManager.default.fileExists(atPath: path) {
                throw LooperError.installFailed(status: 1, message: "The installer finished but the expected content is missing for \(package.displayName).")
            }
        case .musicAppsArchive:
            try musicAppsStore.install(
                archive: cachedPackage,
                package: package,
                workDirectory: paths.cache.appendingPathComponent("tmp", isDirectory: true)
            )
        }
    }
}

private struct StaticManifestProvider: ContentProvider {
    let id = "static-manifest"
    let displayName = "Static Manifest"

    var manifest: LoopManifest
    var packageInstaller = PackageInstaller()

    func discoverCatalogue() -> LoopManifest {
        manifest
    }

    func detectInstalledContent(in manifest: LoopManifest) -> InstalledContent {
        var packageIDs = Set<String>()
        var receipts = Set<String>()

        for package in manifest.packages {
            guard let receipt = package.pkgIdentifier else { continue }
            guard packageInstaller.isInstalled(package) else { continue }
            packageIDs.insert(package.id)
            receipts.insert(receipt)
        }

        return InstalledContent(installedPackageIDs: packageIDs, installedReceiptIdentifiers: receipts)
    }
}
