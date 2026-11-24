import Foundation
import Darwin

/// Small, dependency-free CLI for lab tools and troubleshooting.
///
/// The GUI app should call into the same core types rather than shelling out
/// long term, but keeping the command surface simple makes deployment and MDM
/// testing much easier.
struct LooperCLI {
    static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        switch command {
        case "logic-update-ids":
            for id in MusicAppsContentStore.logicUpdatesForSharedLibrary().sorted() { print(id) }

        case "connect-shared-library":
            try MusicAppsContentStore.connectSharedLibrary()

        case "bootstrap":
            try LooperPaths().prepareServiceLayout()
            print("Prepared Looper service layout.")

        case "request-scheduled-run":
            guard !LooperSettingsStore.managedKeys().contains("ScheduledInstallEnabled") else {
                print("Scheduled installs are managed by the device profile.")
                return
            }
            if let quietHours = try value(after: "--quiet-hours", in: arguments),
               scheduledRunIsQuietNow(quietHours) {
                print("Skipped scheduled run during quiet hours.")
                return
            }
            let appContentSets = try value(after: "--app-content-sets", in: arguments).map(decodeAppContentSets) ?? [:]
            let paths = LooperPaths()
            let settings = LooperSettingsStore(url: paths.settingsFile).load()
            try PendingRequestStore(url: paths.requestFile).requestRun(
                appContentSets: appContentSets,
                excludedPackageIDs: settings.excludedPackageIDs,
                packagePriorities: settings.packagePriorities
            )

        case "install":
            let paths = LooperPaths()
            let settings = LooperSettingsStore(url: paths.settingsFile).load()
            let managedKeys = LooperSettingsStore.managedKeys()
            let deviceService = arguments.contains("--device-service")
            let isService = deviceService || arguments.contains("--service")
            let isPreload = arguments.contains("--managed-preload")
            if isPreload && !LooperSettingsStore.managedPreloadEnabled { return }
            let isScheduled = arguments.contains("--scheduled")
            if isScheduled && settings.scheduledInstallEnabled != true {
                print("Scheduled installs are disabled.")
                return
            }
            try paths.prepareServiceLayout()
            let events = LooperEventStore(url: paths.eventLogFile)
            let manifestURL = try value(after: "--manifest", in: arguments).map(fileURL) ?? defaultManifestURL()
            // A Jamf run and the bundled service can share the system cache and state.
            let lockPath = paths.applicationSupport.appendingPathComponent("install.lock").path
            let lock = geteuid() == 0 ? open(lockPath, O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDWR, 0o600) : -1
            defer { if lock >= 0 { close(lock) } }
            if geteuid() == 0 && (lock < 0 || flock(lock, LOCK_EX) != 0) {
                throw LooperError.scheduleFailed("Could not lock the system install queue.")
            }
            let requests = (isScheduled || isPreload) ? PendingRequests() : try processPendingRequests()
            if isService && requests.runRequestedAt == nil {
                return
            }
            let musicAppsStore = musicAppsStore(
                for: deviceService ? nil : try value(after: "--user-home", in: arguments) ?? requests.requestingUserHomePath,
                ownerUserID: deviceService ? nil : requests.requestingUserID,
                ownerGroupID: deviceService ? nil : requests.requestingGroupID
            )
            let runRequestID = requests.runRequestID ?? UUID().uuidString
            let hasDeleteRequests = !requests.deletePackageIdentifiers.isEmpty
            let hasInstallRequest = requests.runRequestedAt != nil
            let handledDeletesOnly = hasDeleteRequests && !hasInstallRequest
            if handledDeletesOnly {
                events.append(LooperEvent(
                    level: .info,
                    category: "Run",
                    message: "Helper run finished.",
                    detail: "Processed delete request without starting an install pass."
                ))
                print("Processed delete request without starting an install pass.")
                return
            }
            if let quietHours = try ((isScheduled || isPreload) ? settings.scheduleQuietHours : value(after: "--quiet-hours", in: arguments)),
               scheduledRunIsQuietNow(quietHours) {
                events.append(LooperEvent(
                    level: .info,
                    category: "Schedule",
                    message: "Scheduled run skipped.",
                    detail: "Current time falls inside quiet hours \(quietHours).",
                    requestID: runRequestID
                ))
                print("Skipped scheduled run: quiet hours \(quietHours).")
                return
            }
            if let exclusion = try value(after: "--exclude", in: arguments), !exclusion.isEmpty {
                events.append(LooperEvent(
                    level: .info,
                    category: "Schedule",
                    message: "Schedule exclusion policy loaded.",
                    detail: exclusion,
                    requestID: runRequestID
                ))
            }
            let cliApps = runList(after: "--app", in: arguments)
            let cliSets = runList(after: "--set", in: arguments)
            let cliAppContentSets = try value(after: "--app-content-sets", in: arguments).map(decodeAppContentSets)
            let scopeIsManaged = managedKeys.contains("RunAppContentSets")
            let requestedAppContentSets = requests.runAppContentSets.isEmpty
                ? settings.runAppContentSets : requests.runAppContentSets
            let appContentSets = scopeIsManaged ? settings.runAppContentSets
                : cliAppContentSets ?? ((cliApps == nil && cliSets == nil) ? requestedAppContentSets : [:])
            let exclusions = managedKeys.contains("ExcludedPackageIDs") || requests.runAppContentSets.isEmpty
                ? settings.excludedPackageIDs : requests.excludedPackageIDs
            let priorities = managedKeys.contains("PackagePriorities") || requests.runAppContentSets.isEmpty
                ? settings.packagePriorities : requests.packagePriorities
            let overrides = scopeIsManaged || managedKeys.contains("AppPackageOverrides") ? settings.appPackageOverrides
                : requests.appPackageOverrides ?? settings.appPackageOverrides
            var policy = LooperPolicy(
                targetApps: cliApps ?? requests.runTargetApps,
                contentSets: cliSets ?? requests.runPackageSets,
                appContentSets: appContentSets,
                excludedPackageIDs: Set(exclusions),
                packagePriorities: priorities,
                appPackageOverrides: overrides,
                dryRun: arguments.contains("--dry-run")
            )
            if let id = requests.requestedPackageID {
                policy.requestedPackageID = id
                policy.targetApps = []
                policy.contentSets = []
                if !scopeIsManaged { policy.appContentSets = [:] }
                if !managedKeys.contains("AppPackageOverrides") { policy.appPackageOverrides = nil }
                if !managedKeys.contains("ExcludedPackageIDs") { policy.excludedPackageIDs = [] }
            }
            let results = HelperResultStore(directory: paths.resultDirectory)
            let scopeDescription = policy.requestedPackageID.map { "Library package \($0)" } ?? policy.describeScope()
            events.append(LooperEvent(
                level: .info,
                category: "Run",
                message: "Helper run started.",
                detail: scopeDescription,
                requestID: runRequestID
            ))
            try? results.save(HelperResult(
                id: runRequestID,
                kind: .installRun,
                status: .running,
                message: "Running \(scopeDescription)."
            ))
            let provider = AppleAudioPackageProvider(manifestURL: manifestURL, musicAppsStore: musicAppsStore)
            let summary = try await LoopInstaller(musicAppsStore: musicAppsStore, eventStore: events, requestID: runRequestID)
                .reconcile(provider: provider, policy: policy)
            for package in summary.installed {
                events.append(LooperEvent(
                    level: .success,
                    category: "Install",
                    message: "Installed \(package.displayName).",
                    packageIdentifier: package.pkgIdentifier ?? package.id,
                    requestID: runRequestID
                ))
            }
            try? results.save(HelperResult(
                id: runRequestID,
                kind: .installRun,
                status: summary.failed.isEmpty && !summary.requiresAttention ? .succeeded : .failed,
                message: summary.outcome
            ))
            events.append(LooperEvent(
                level: summary.stopped ? .warning : (summary.failed.isEmpty ? .success : .warning),
                category: "Run",
                message: summary.stopped ? "Helper run stopped." : "Helper run finished.",
                detail: summary.outcome,
                requestID: runRequestID
            ))
            printSummary(summary)
            if !summary.failed.isEmpty || summary.requiresAttention {
                let anotherRunIsQueued = deviceService && PendingRequestStore.loadAll(in: paths.requestDirectory).runRequestedAt != nil
                if !anotherRunIsQueued { Foundation.exit(2) }
            }

        case "list":
            let manifestURL = try value(after: "--manifest", in: arguments).map(fileURL) ?? defaultManifestURL()
            let musicAppsStore = musicAppsStore(for: try value(after: "--user-home", in: arguments))
            let manifest = arguments.contains("--apple-catalogue")
                ? try AppleContentDiscovery.appleCatalogueManifest(musicAppsStore: musicAppsStore)
                : try ManifestLoader.load(from: manifestURL)
            for package in manifest.packages {
                print("\(package.id)\t\(package.displayName)")
            }

        case "plan":
            let policy = LooperPolicy(
                targetApps: runList(after: "--app", in: arguments) ?? [],
                contentSets: runList(after: "--set", in: arguments) ?? [],
                dryRun: arguments.contains("--dry-run")
            )
            let musicAppsStore = musicAppsStore(for: try value(after: "--user-home", in: arguments))
            let provider = AppleAudioPackageProvider(musicAppsStore: musicAppsStore)
            let plan = try await LoopInstaller(musicAppsStore: musicAppsStore).plan(provider: provider, policy: policy)
            printPlan(plan)

        case "reconcile":
            let policy = LooperPolicy(
                targetApps: runList(after: "--app", in: arguments) ?? [],
                contentSets: runList(after: "--set", in: arguments) ?? [],
                dryRun: arguments.contains("--dry-run")
            )
            let musicAppsStore = musicAppsStore(for: try value(after: "--user-home", in: arguments))
            let provider = AppleAudioPackageProvider(musicAppsStore: musicAppsStore)
            let summary = try await LoopInstaller(musicAppsStore: musicAppsStore).reconcile(provider: provider, policy: policy)
            printSummary(summary)
            if !summary.failed.isEmpty || summary.requiresAttention {
                Foundation.exit(2)
            }

        case "catalogue", "catalog":
            let manifest: LoopManifest
            if arguments.contains("--receipts") {
                manifest = AppleContentDiscovery.discoveredReceiptManifest()
            } else if arguments.contains("--bundled-apps") {
                manifest = try AppleContentDiscovery.bundledAppCatalogueManifest()
            } else {
                let musicAppsStore = musicAppsStore(for: try value(after: "--user-home", in: arguments))
                manifest = try AppleContentDiscovery.appleCatalogueManifest(musicAppsStore: musicAppsStore)
            }
            if let outputPath = try value(after: "--write", in: arguments).map(fileURL) {
                try FileManager.default.createDirectory(at: outputPath.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ManifestLoader.save(manifest, to: outputPath)
                print("Wrote \(manifest.packages.count) catalogue packages to \(outputPath.path)")
            } else {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                FileHandle.standardOutput.write(try encoder.encode(manifest))
                print()
            }

        case "install-musicapps-pack":
            let identifier = try value(after: "--package", in: arguments)
                ?? arguments.dropFirst().first
                ?? { throw LooperError.missingArgument("--package") }()
            try await installMusicAppsPackage(
                identifier: identifier,
                store: musicAppsStore(for: try value(after: "--user-home", in: arguments))
            )

        case "delete":
            let identifier = try value(after: "--package", in: arguments)
                ?? arguments.dropFirst().first
                ?? { throw LooperError.missingArgument("--package") }()
            let summary = try PackageInstaller().deletePackageContent(identifier: identifier)
            try recordManagedRemoval(identifier: identifier)
            print("Deleted: \(summary.identifier)")
            print("Removed files: \(summary.removedFiles)")
            print("Removed empty folders: \(summary.removedDirectories)")
            print("Skipped protected paths: \(summary.skippedPaths.count)")

        case "status":
            let state = try await LoopInstaller().state()
            let receipts = PackageInstaller().installedAppleAudioContent()
            let schedule = LaunchAgentScheduler().status()
            print("Last check: \(state.lastCheck.map(String.init(describing:)) ?? "never")")
            print("Installed by Looper state: \(state.installedPackages.count)")
            print("Installed Apple audio receipts: \(receipts.count)")
            print("Failed: \(state.failedPackages.count)")
            print("Schedule: \(schedule.isInstalled ? "installed" : "not installed")")

        case "identity":
            try printIdentity()

        case "schedule":
            let interval = try value(after: "--interval", in: arguments).flatMap(TimeInterval.init) ?? 21_600
            let manifestURL = try value(after: "--manifest", in: arguments).map(fileURL)
            let executableURL = currentExecutableURL()
            try LaunchAgentScheduler().install(executableURL: executableURL, manifestURL: manifestURL, interval: interval)
            print("Scheduled Looper every \(Int(interval)) seconds.")

        case "unschedule":
            try LaunchAgentScheduler().uninstall()
            print("Removed Looper schedule.")

        case "uninstall":
            try uninstall(forgetState: arguments.contains("--forget-state"))

        case "help", "--help", "-h":
            printHelp()

        default:
            throw LooperError.unknownCommand(command)
        }
    }

    private static func value(after flag: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { throw LooperError.missingArgument(flag) }
        return arguments[valueIndex]
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    private static func defaultManifestURL() -> URL {
        LooperPaths.defaultManifestURL
    }

    private static func currentExecutableURL() -> URL {
        let path = CommandLine.arguments[0]
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        } else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path)
                .standardizedFileURL
        }
    }

    private static func resolvedExecutableURL() -> URL {
        currentExecutableURL().resolvingSymlinksInPath()
    }

    private static func musicAppsStore(
        for userHomePath: String?,
        ownerUserID: Int? = nil,
        ownerGroupID: Int? = nil
    ) -> MusicAppsContentStore {
        guard let userHomePath,
              !userHomePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MusicAppsContentStore()
        }

        let homeURL = URL(
            fileURLWithPath: NSString(string: userHomePath).expandingTildeInPath,
            isDirectory: true
        )
        let inferredOwnership = ownerIDs(for: homeURL)

        return MusicAppsContentStore(
            userHomeDirectory: homeURL,
            ownerUserID: ownerUserID ?? inferredOwnership.userID,
            ownerGroupID: ownerGroupID ?? inferredOwnership.groupID
        )
    }

    private static func ownerIDs(for url: URL) -> (userID: Int?, groupID: Int?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (nil, nil)
        }
        return (
            (attributes[.ownerAccountID] as? NSNumber)?.intValue,
            (attributes[.groupOwnerAccountID] as? NSNumber)?.intValue
        )
    }

    private static func printIdentity() throws {
        let executableURL = resolvedExecutableURL()
        let attributes = try FileManager.default.attributesOfItem(atPath: executableURL.path)
        let modified = attributes[.modificationDate] as? Date
        let size = attributes[.size] as? NSNumber
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "none"

        print("Looper helper identity")
        print("Executable: \(executableURL.path)")
        print("SHA-256: \(try Hashing.sha256Hex(of: executableURL))")
        print("Modified: \(modified.map(String.init(describing:)) ?? "unknown")")
        print("Size: \(size?.stringValue ?? "unknown") bytes")
        print("Bundle identifier: \(bundleIdentifier)")
        print("Protocol: requests-v2 events-v1 results-v1")
    }

    private static func printSummary(_ summary: InstallSummary) {
        if summary.stopped {
            print("Stopped: \(summary.stopReason ?? "yes")")
        }
        print("Installed: \(summary.installed.count)")
        print("Skipped: \(summary.skipped.count)")
        print("Failed: \(summary.failed.count)")

        for (package, error) in summary.failed {
            print("FAILED \(package.displayName): \(error)")
        }
    }

    private static func runList(after flag: String, in arguments: [String]) -> [String]? {
        guard let value = try? value(after: flag, in: arguments) else {
            return nil
        }
        return value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func decodeAppContentSets(_ encoded: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for entry in encoded.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let app = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let setText = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty else { continue }
            result[app] = setText == "*" ? [] : setText
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return result
    }

    private static func scheduledRunIsQuietNow(_ encodedHours: String, now: Date = Date()) -> Bool {
        let parts = encodedHours.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
        guard parts.count == 2,
              (0...23).contains(parts[0]),
              (0...23).contains(parts[1]) else {
            return false
        }

        let hour = Calendar.current.component(.hour, from: now)
        let start = parts[0]
        let end = parts[1]
        if start == end { return true }
        if start < end {
            return (start..<end).contains(hour)
        }
        return hour >= start || hour < end
    }

    private static func processPendingRequests() throws -> PendingRequests {
        let paths = LooperPaths()
        var requests = try PendingRequestStore.consumeAll(in: paths.requestDirectory)
        if requests.requestedPackageID == nil {
            requests.merge(try consumeLegacyRequests(at: paths.legacyRequestFile))
        }
        let deletes = requests.deletePackageIdentifiers
        guard !deletes.isEmpty else { return requests }

        let results = HelperResultStore(directory: paths.resultDirectory)
        let events = LooperEventStore(url: paths.eventLogFile)
        events.append(LooperEvent(
            level: .info,
            category: "Requests",
            message: "Processing \(deletes.count) delete request\(deletes.count == 1 ? "" : "s")."
        ))
        for identifier in deletes {
            let requestID = requests.deleteRequestIDs[identifier] ?? UUID().uuidString
            do {
                events.append(LooperEvent(
                    level: .info,
                    category: "Delete",
                    message: "Delete started.",
                    packageIdentifier: identifier,
                    requestID: requestID
                ))
                try results.save(HelperResult(
                    id: requestID,
                    kind: .deletePackage,
                    status: .running,
                    message: "Deleting \(identifier).",
                    identifier: identifier
                ))
                let summary = try PackageInstaller().deletePackageContent(identifier: identifier) { message in
                    events.append(LooperEvent(
                        level: .info,
                        category: "Delete",
                        message: message,
                        packageIdentifier: identifier,
                        requestID: requestID
                    ))
                    try? results.save(HelperResult(
                        id: requestID,
                        kind: .deletePackage,
                        status: .running,
                        message: message,
                        identifier: identifier
                    ))
                }
                try recordManagedRemoval(identifier: identifier)
                try results.save(HelperResult(
                    id: requestID,
                    kind: .deletePackage,
                    status: .succeeded,
                    message: "Deleted \(identifier): \(summary.removedFiles) files and \(summary.removedDirectories) empty folders.",
                    identifier: identifier
                ))
                events.append(LooperEvent(
                    level: .success,
                    category: "Delete",
                    message: "Delete finished.",
                    detail: "\(summary.removedFiles) files, \(summary.removedDirectories) empty folders, \(summary.skippedPaths.count) protected paths skipped.",
                    packageIdentifier: identifier,
                    requestID: requestID
                ))
                print("Deleted pending package \(identifier): \(summary.removedFiles) files, \(summary.removedDirectories) empty folders.")
            } catch {
                try? results.save(HelperResult(
                    id: requestID,
                    kind: .deletePackage,
                    status: .failed,
                    message: "Could not delete \(identifier): \(error)",
                    identifier: identifier
                ))
                events.append(LooperEvent(
                    level: .error,
                    category: "Delete",
                    message: "Delete failed.",
                    detail: "\(error)",
                    packageIdentifier: identifier,
                    requestID: requestID
                ))
                fputs("Pending delete failed for \(identifier): \(error)\n", stderr)
            }
        }
        return requests
    }

    private static func recordManagedRemoval(identifier: String) throws {
        let paths = LooperPaths()
        let stateStore = StateStore(url: paths.stateFile)
        let manifest = AppleContentDiscovery.loadManagedOrDiscoveredManifest()
        let package = manifest.packages.first { $0.pkgIdentifier == identifier }
        let packageID = package?.id ?? identifier
        var state = try stateStore.load()
        state.installedPackages[packageID] = nil
        state.failedPackages[packageID] = nil
        state.removedPackages[packageID] = RemovedPackage(
            displayName: package?.displayName ?? identifier,
            removedAt: Date(),
            pkgIdentifier: identifier
        )
        try FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
        try stateStore.save(state)
    }

    private static func consumeLegacyRequests(at url: URL) throws -> PendingRequests {
        let requests = PendingRequestStore(url: url).load()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return requests
    }

    private static func uninstall(forgetState: Bool) throws {
        let paths = LooperPaths()
        let launchAgent = URL(fileURLWithPath: "/Library/LaunchAgents/com.looper.agent.plist")
        // Looper removes its own scheduling/state/cache files only. Apple loop
        // content is intentionally left in place unless we add a separate,
        // explicit content-removal command later.
        try? FileManager.default.removeItem(at: launchAgent)
        try? FileManager.default.removeItem(at: paths.cache)
        if forgetState {
            try? FileManager.default.removeItem(at: paths.applicationSupport)
        }
        print("Looper support files removed. Apple loop content was left untouched.")
    }

    private static func printHelp() {
        print("""
        looper install [--manifest /path/to/loops.json] [--app GarageBand] [--set Essential] [--user-home /Users/name] [--dry-run]
        looper install --scheduled [--dry-run]
        looper reconcile [--app GarageBand] [--set Essential] [--user-home /Users/name] [--dry-run]
        looper plan [--app GarageBand] [--set Essential] [--user-home /Users/name] [--dry-run]
        looper list --manifest /path/to/loops.json
        looper catalogue [--write /path/to/loops.json] [--receipts] [--user-home /Users/name]
        looper catalogue --bundled-apps [--write /path/to/loops.json]
        looper list [--manifest /path/to/loops.json] [--apple-catalogue] [--user-home /Users/name]
        looper install-musicapps-pack --package 0056_afrobeats [--user-home /Users/name]
        looper bootstrap
        looper delete --package com.apple.pkg.MAContent10_AssetPack_...
        looper status
        looper identity
        looper schedule [--interval seconds] [--manifest /path/to/loops.json]
        looper unschedule
        looper uninstall [--forget-state]
        """)
    }

    private static func printPlan(_ plan: ReconcilePlan) {
        print("Plan: \(plan.id)")
        print("Provider: \(plan.providerName)")
        print("Install: \(plan.installCount)")
        print("Skip: \(plan.skipCount)")

        for entry in plan.entries {
            print("\(entry.action.rawValue.uppercased())\t\(entry.package.displayName)\t\(entry.reason)")
        }
    }

    private static func installMusicAppsPackage(identifier: String, store: MusicAppsContentStore) async throws {
        let manifest = try store.catalogueManifest()
        guard let package = manifest.packages.first(where: { $0.id == identifier }) else {
            throw LooperError.catalogueUnavailable("No Music Apps package named \(identifier) was found.")
        }

        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Looper/MusicAppsProbe", isDirectory: true)
        let archiveURL = cacheURL
            .appendingPathComponent(package.id)
            .appendingPathExtension("aar")
        let partialURL = cacheURL
            .appendingPathComponent(package.id)
            .appendingPathExtension("aar.part")

        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        print("Package: \(package.displayName)")
        print("Identifier: \(package.id)")
        print("Download: \(package.url.absoluteString)")

        let progressPrinter = MusicAppsDownloadProgressPrinter()
        try await ResumableDownloader().download(
            package: package,
            to: archiveURL,
            partialFile: partialURL
        ) { progress in
            guard let expected = progress.expectedBytes, expected > 0 else { return }
            let percent = Int((Double(progress.receivedBytes) / Double(expected) * 100).rounded(.down))
            progressPrinter.printIfNeeded(percent)
        }

        try store.install(archive: archiveURL, package: package, workDirectory: cacheURL)
        print("Installed Music Apps content for \(package.displayName).")
    }
}

@main
enum LooperCommand {
    static func main() async {
        prepareLaunchDaemonEnvironment()
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let drainQueue = arguments == ["install", "--device-service"]
            repeat {
                try await LooperCLI.run(arguments: arguments)
            } while drainQueue && PendingRequestStore.loadAll(in: LooperPaths().requestDirectory).runRequestedAt != nil
        } catch {
            fputs("looper: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    /// Launch daemons do not always inherit the interactive user's temporary
    /// directory. Giving Foundation and Apple's installer tools a known temp
    /// root avoids obscure failures from lower-level mktemp calls.
    private static func prepareLaunchDaemonEnvironment() {
        guard ProcessInfo.processInfo.environment["TMPDIR"]?.isEmpty ?? true else {
            return
        }

        let temporaryDirectory = URL(fileURLWithPath: "/Library/Caches/Looper/tmp", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            setenv("TMPDIR", temporaryDirectory.path, 1)
        } catch {
            setenv("TMPDIR", "/tmp", 1)
        }
    }
}

private extension LooperPolicy {
    func describeScope() -> String {
        if !appContentSets.isEmpty {
            return appContentSets
                .keys
                .sorted()
                .map { app in
                    let sets = appContentSets[app] ?? []
                    return "\(app): \(sets.isEmpty ? "all content" : sets.joined(separator: ", "))"
                }
                .joined(separator: "; ")
        }

        let appText = targetApps.isEmpty ? "all apps" : targetApps.joined(separator: ", ")
        let setText = contentSets.isEmpty ? "all content" : contentSets.joined(separator: ", ")
        return "\(appText), \(setText)"
    }
}

private final class MusicAppsDownloadProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPrintedPercent = -1

    func printIfNeeded(_ percent: Int) {
        lock.lock()
        defer { lock.unlock() }

        if percent >= lastPrintedPercent + 10 || percent == 100 {
            lastPrintedPercent = percent
            print("Downloaded \(percent)%")
        }
    }
}
