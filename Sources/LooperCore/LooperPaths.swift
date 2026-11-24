import Foundation
import Darwin

/// Centralised filesystem layout for Looper's mutable state.
///
/// The defaults are system-wide because lab machines commonly install content
/// once for all users. Tests and future per-user modes can inject different
/// roots without touching the installer.
public struct LooperPaths: Sendable {
    public static let deviceHelperLabel = "com.maxhewett.Looper.device-helper"
    public static var usesDeviceHelper: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(deviceHelperLabel).plist")
    }

    public static let defaultManifestURL = URL(fileURLWithPath: "/Library/Application Support/Looper/loops.json")

    public var applicationSupport: URL
    public var cache: URL
    public var logDirectory: URL
    public var stateFile: URL
    public var requestDirectory: URL
    public var resultDirectory: URL
    public var eventLogFile: URL
    public var legacyEventLogFile: URL
    public var settingsFile: URL
    public var requestFile: URL
    public var legacyRequestFile: URL

    public init(
        applicationSupport: URL = URL(fileURLWithPath: "/Library/Application Support/Looper", isDirectory: true),
        cache: URL = URL(fileURLWithPath: "/Library/Caches/Looper", isDirectory: true),
        logDirectory: URL = URL(fileURLWithPath: "/var/log/Looper", isDirectory: true)
    ) {
        self.applicationSupport = applicationSupport
        self.cache = cache
        self.logDirectory = logDirectory
        self.stateFile = applicationSupport.appendingPathComponent("state.json")
        self.requestDirectory = applicationSupport.appendingPathComponent("Requests", isDirectory: true)
        self.resultDirectory = applicationSupport.appendingPathComponent("Results", isDirectory: true)
        self.eventLogFile = logDirectory.appendingPathComponent("events.jsonl")
        self.legacyEventLogFile = applicationSupport.appendingPathComponent("events.jsonl")
        self.settingsFile = applicationSupport.appendingPathComponent("settings.json")
        self.requestFile = Self.userRequestFile(in: requestDirectory)
        self.legacyRequestFile = applicationSupport.appendingPathComponent("requests.json")
    }

    /// Create support directories before state writes or downloads begin.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
    }

    /// Prepare the system-wide service layout used by the privileged helper.
    ///
    /// The app itself may be launched by a standard user after simply copying
    /// `Looper.app` into `/Applications`. Once the helper is approved, it runs
    /// as root and can create the shared spool/cache/log folders that the app
    /// needs in order to request work.
    public func prepareServiceLayout() throws {
        try prepare()
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("tmp", isDirectory: true), withIntermediateDirectories: true)

        chmod(applicationSupport.path, 0o755)
        chmod(requestDirectory.path, 0o1777)
        chmod(resultDirectory.path, 0o755)
        chmod(cache.path, 0o775)
        chmod(cache.appendingPathComponent("tmp", isDirectory: true).path, 0o755)
        chmod(logDirectory.path, 0o755)
    }

    /// Completed downloads are kept so reruns do not redownload a verified
    /// package when an install step needs to be retried.
    public func packageCacheFile(for package: LoopPackage) -> URL {
        cache.appendingPathComponent(package.cacheName).appendingPathExtension(package.cacheFileExtension)
    }

    /// Partial files are separate from completed packages. A package is only
    /// promoted after length and hash checks pass.
    public func partialDownloadFile(for package: LoopPackage) -> URL {
        cache.appendingPathComponent(package.cacheName).appendingPathExtension("\(package.cacheFileExtension).part")
    }
}

private extension LoopPackage {
    var cacheName: String {
        guard let version = packageVersion, !version.isEmpty,
              version.range(of: #"^[0-9A-Za-z._-]+$"#, options: .regularExpression) != nil else { return id }
        return "\(id)-v\(version)"
    }

    var cacheFileExtension: String {
        switch installFormat {
        case .installerPackage:
            return "pkg"
        case .musicAppsArchive:
            return "aar"
        }
    }
}

/// Small hand-off files for actions that must be completed by the helper.
///
/// Managed installs create a narrow writable drop point for these files so
/// standard users can ask the root helper to do work without getting direct
/// write access to Apple Loop locations.
public struct PendingRequests: Codable, Sendable {
    public var runRequestedAt: Date?
    public var requestedPackageID: String?
    public var runRequestID: String?
    public var stopRequestedAt: Date?
    public var stopRequestID: String?
    public var runTargetApps: [String]
    public var runPackageSets: [String]
    public var runAppContentSets: [String: [String]]
    public var appPackageOverrides: [String: AppPackageOverrides]?
    public var excludedPackageIDs: [String]
    public var packagePriorities: [String: Int]
    public var requestingUserHomePath: String?
    public var requestingUserID: Int?
    public var requestingGroupID: Int?
    public var deletePackageIdentifiers: [String]
    public var deleteRequestIDs: [String: String]

    public init(
        runRequestedAt: Date? = nil,
        runRequestID: String? = nil,
        stopRequestedAt: Date? = nil,
        stopRequestID: String? = nil,
        runTargetApps: [String] = [],
        runPackageSets: [String] = [],
        runAppContentSets: [String: [String]] = [:],
        appPackageOverrides: [String: AppPackageOverrides]? = nil,
        excludedPackageIDs: [String] = [],
        packagePriorities: [String: Int] = [:],
        requestingUserHomePath: String? = nil,
        requestingUserID: Int? = nil,
        requestingGroupID: Int? = nil,
        deletePackageIdentifiers: [String] = [],
        deleteRequestIDs: [String: String] = [:]
    ) {
        self.runRequestedAt = runRequestedAt
        self.runRequestID = runRequestID
        self.stopRequestedAt = stopRequestedAt
        self.stopRequestID = stopRequestID
        self.runTargetApps = runTargetApps
        self.runPackageSets = runPackageSets
        self.runAppContentSets = runAppContentSets
        self.appPackageOverrides = appPackageOverrides
        self.excludedPackageIDs = excludedPackageIDs
        self.packagePriorities = packagePriorities
        self.requestingUserHomePath = requestingUserHomePath
        self.requestingUserID = requestingUserID
        self.requestingGroupID = requestingGroupID
        self.deletePackageIdentifiers = deletePackageIdentifiers
        self.deleteRequestIDs = deleteRequestIDs
    }

    private enum CodingKeys: String, CodingKey {
        case runRequestedAt
        case requestedPackageID
        case runRequestID
        case stopRequestedAt
        case stopRequestID
        case runTargetApps
        case runPackageSets
        case runAppContentSets
        case appPackageOverrides
        case excludedPackageIDs
        case packagePriorities
        case requestingUserHomePath
        case requestingUserID
        case requestingGroupID
        case deletePackageIdentifiers
        case deleteRequestIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runRequestedAt = try container.decodeIfPresent(Date.self, forKey: .runRequestedAt)
        requestedPackageID = try container.decodeIfPresent(String.self, forKey: .requestedPackageID)
        runRequestID = try container.decodeIfPresent(String.self, forKey: .runRequestID)
        stopRequestedAt = try container.decodeIfPresent(Date.self, forKey: .stopRequestedAt)
        stopRequestID = try container.decodeIfPresent(String.self, forKey: .stopRequestID)
        runTargetApps = try container.decodeIfPresent([String].self, forKey: .runTargetApps) ?? []
        runPackageSets = try container.decodeIfPresent([String].self, forKey: .runPackageSets) ?? []
        runAppContentSets = try container.decodeIfPresent([String: [String]].self, forKey: .runAppContentSets) ?? [:]
        appPackageOverrides = try container.decodeIfPresent([String: AppPackageOverrides].self, forKey: .appPackageOverrides)
        excludedPackageIDs = try container.decodeIfPresent([String].self, forKey: .excludedPackageIDs) ?? []
        packagePriorities = try container.decodeIfPresent([String: Int].self, forKey: .packagePriorities) ?? [:]
        requestingUserHomePath = try container.decodeIfPresent(String.self, forKey: .requestingUserHomePath)
        requestingUserID = try container.decodeIfPresent(Int.self, forKey: .requestingUserID)
        requestingGroupID = try container.decodeIfPresent(Int.self, forKey: .requestingGroupID)
        deletePackageIdentifiers = try container.decodeIfPresent([String].self, forKey: .deletePackageIdentifiers) ?? []
        deleteRequestIDs = try container.decodeIfPresent([String: String].self, forKey: .deleteRequestIDs) ?? [:]
    }

    public mutating func merge(_ other: PendingRequests) {
        if let requestDate = other.runRequestedAt,
           runRequestedAt.map({ requestDate > $0 }) ?? true {
            runRequestedAt = requestDate
            requestedPackageID = other.requestedPackageID
            runRequestID = other.runRequestID
            runTargetApps = other.runTargetApps
            runPackageSets = other.runPackageSets
            runAppContentSets = other.runAppContentSets
            appPackageOverrides = other.appPackageOverrides
            excludedPackageIDs = other.excludedPackageIDs
            packagePriorities = other.packagePriorities
            requestingUserHomePath = other.requestingUserHomePath
            requestingUserID = other.requestingUserID
            requestingGroupID = other.requestingGroupID
        }
        if let requestDate = other.stopRequestedAt,
           stopRequestedAt.map({ requestDate > $0 }) ?? true {
            stopRequestedAt = requestDate
            stopRequestID = other.stopRequestID
        }
        for identifier in other.deletePackageIdentifiers where !deletePackageIdentifiers.contains(identifier) {
            deletePackageIdentifiers.append(identifier)
        }
        deleteRequestIDs.merge(other.deleteRequestIDs) { existing, _ in existing }
    }

    public var isEmpty: Bool {
        runRequestedAt == nil
            && stopRequestedAt == nil
            && deletePackageIdentifiers.isEmpty
    }
}

/// Result records written by the privileged helper after it processes a
/// request from the spool directory.
public struct HelperResult: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case installRun
        case deletePackage
    }

    public enum Status: String, Codable, Sendable {
        case running
        case succeeded
        case failed
    }

    public var id: String
    public var kind: Kind
    public var status: Status
    public var message: String
    public var identifier: String?
    public var displayName: String?
    public var updatedAt: Date

    public init(
        id: String,
        kind: Kind,
        status: Status,
        message: String,
        identifier: String? = nil,
        displayName: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.message = message
        self.identifier = identifier
        self.displayName = displayName
        self.updatedAt = updatedAt
    }
}

/// Human-readable operational events for the app's logging timeline.
///
/// This supplements daemon stdout/stderr with structured state that survives
/// short helper runs and is easy for the UI to group, filter, and colour.
public struct LooperEvent: Codable, Sendable, Identifiable {
    public enum Level: String, Codable, Sendable {
        case debug
        case info
        case warning
        case error
        case success
    }

    public var id: String
    public var timestamp: Date
    public var level: Level
    public var category: String
    public var message: String
    public var detail: String?
    public var packageIdentifier: String?
    public var requestID: String?

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        level: Level,
        category: String,
        message: String,
        detail: String? = nil,
        packageIdentifier: String? = nil,
        requestID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.detail = detail
        self.packageIdentifier = packageIdentifier
        self.requestID = requestID
    }
}

public enum LooperHelperRunMode: String, Codable, Sendable, CaseIterable {
    case sequential
    case staged
}

public struct LooperSettings: Codable, Sendable {
    public var scheduledInstallEnabled: Bool?
    public var scheduleQuietHours: String?
    public var logRetentionDays: Int
    public var helperRunMode: LooperHelperRunMode
    public var runAppContentSets: [String: [String]]
    public var appPackageOverrides: [String: AppPackageOverrides]?
    public var excludedPackageIDs: [String]
    public var packagePriorities: [String: Int]
    public var notifyNewLoopsAvailable: Bool
    public var notifyRelaunchPrompts: Bool
    public var notifyRunFailures: Bool
    public var notifyRunSummaries: Bool

    public init(
        logRetentionDays: Int = 30,
        helperRunMode: LooperHelperRunMode = .sequential,
        runAppContentSets: [String: [String]] = [
            "GarageBand": [],
            "Logic Pro": [],
        ],
        appPackageOverrides: [String: AppPackageOverrides]? = nil,
        excludedPackageIDs: [String] = [],
        packagePriorities: [String: Int] = [:],
        notifyNewLoopsAvailable: Bool = true,
        notifyRelaunchPrompts: Bool = true,
        notifyRunFailures: Bool = true,
        notifyRunSummaries: Bool = false
    ) {
        self.logRetentionDays = logRetentionDays
        self.helperRunMode = helperRunMode
        self.runAppContentSets = runAppContentSets
        self.appPackageOverrides = appPackageOverrides
        self.excludedPackageIDs = excludedPackageIDs
        self.packagePriorities = packagePriorities
        self.notifyNewLoopsAvailable = notifyNewLoopsAvailable
        self.notifyRelaunchPrompts = notifyRelaunchPrompts
        self.notifyRunFailures = notifyRunFailures
        self.notifyRunSummaries = notifyRunSummaries
    }

    private enum CodingKeys: String, CodingKey {
        case scheduledInstallEnabled
        case scheduleQuietHours
        case logRetentionDays
        case helperRunMode
        case runAppContentSets
        case appPackageOverrides
        case excludedPackageIDs
        case packagePriorities
        case notifyNewLoopsAvailable
        case notifyRelaunchPrompts
        case notifyRunFailures
        case notifyRunSummaries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scheduledInstallEnabled = try container.decodeIfPresent(Bool.self, forKey: .scheduledInstallEnabled)
        scheduleQuietHours = try container.decodeIfPresent(String.self, forKey: .scheduleQuietHours)
        logRetentionDays = try container.decodeIfPresent(Int.self, forKey: .logRetentionDays) ?? 30
        helperRunMode = try container.decodeIfPresent(LooperHelperRunMode.self, forKey: .helperRunMode) ?? .sequential
        runAppContentSets = try container.decodeIfPresent([String: [String]].self, forKey: .runAppContentSets) ?? [
            "GarageBand": [],
            "Logic Pro": [],
        ]
        appPackageOverrides = try container.decodeIfPresent([String: AppPackageOverrides].self, forKey: .appPackageOverrides)
        excludedPackageIDs = try container.decodeIfPresent([String].self, forKey: .excludedPackageIDs) ?? []
        packagePriorities = try container.decodeIfPresent([String: Int].self, forKey: .packagePriorities) ?? [:]
        notifyNewLoopsAvailable = try container.decodeIfPresent(Bool.self, forKey: .notifyNewLoopsAvailable) ?? true
        notifyRelaunchPrompts = try container.decodeIfPresent(Bool.self, forKey: .notifyRelaunchPrompts) ?? true
        notifyRunFailures = try container.decodeIfPresent(Bool.self, forKey: .notifyRunFailures) ?? true
        notifyRunSummaries = try container.decodeIfPresent(Bool.self, forKey: .notifyRunSummaries) ?? false
    }
}

public final class PendingRequestStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> PendingRequests {
        guard let data = try? Data(contentsOf: url),
              let requests = try? JSONDecoder().decode(PendingRequests.self, from: data) else {
            return PendingRequests()
        }
        return requests
    }

    public func save(_ requests: PendingRequests) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(requests)
        try data.write(to: url, options: [.atomic])
    }

    @discardableResult
    public func appendDelete(identifier: String) throws -> String {
        var requests = load()
        let requestID = requests.deleteRequestIDs[identifier] ?? UUID().uuidString
        if !requests.deletePackageIdentifiers.contains(identifier) {
            requests.deletePackageIdentifiers.append(identifier)
        }
        requests.deleteRequestIDs[identifier] = requestID
        try save(requests)
        return requestID
    }

    @discardableResult
    public func requestRun(
        requestedPackageID: String? = nil,
        targetApps: [String] = [],
        packageSets: [String] = [],
        appContentSets: [String: [String]] = [:],
        appPackageOverrides: [String: AppPackageOverrides]? = nil,
        excludedPackageIDs: [String] = [],
        packagePriorities: [String: Int] = [:],
        requestingUserHomePath: String? = FileManager.default.homeDirectoryForCurrentUser.path,
        requestingUserID: Int? = Int(getuid()),
        requestingGroupID: Int? = Int(getgid())
    ) throws -> String {
        let requestID = UUID().uuidString
        let destination = requestedPackageID == nil ? self : PendingRequestStore(
            url: url.deletingLastPathComponent().appendingPathComponent(requestID + ".json"))
        var requests = requestedPackageID == nil ? load() : PendingRequests()
        requests.runRequestedAt = Date()
        requests.requestedPackageID = requestedPackageID
        requests.runRequestID = requestID
        requests.runTargetApps = targetApps
        requests.runPackageSets = packageSets
        requests.runAppContentSets = appContentSets
        requests.appPackageOverrides = appPackageOverrides
        requests.excludedPackageIDs = excludedPackageIDs
        requests.packagePriorities = packagePriorities
        requests.requestingUserHomePath = requestingUserHomePath
        requests.requestingUserID = requestingUserID
        requests.requestingGroupID = requestingGroupID
        try destination.save(requests)
        return requestID
    }

    @discardableResult
    public func requestStop() throws -> String {
        var requests = load()
        let requestID = UUID().uuidString
        requests.stopRequestedAt = Date()
        requests.stopRequestID = requestID
        try save(requests)
        return requestID
    }

    public func consumeDeletes() throws -> [String] {
        let requests = load()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return requests.deletePackageIdentifiers
    }

    public static func loadAll(in directory: URL) -> PendingRequests {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return PendingRequests()
        }

        var combined = PendingRequests()
        for file in files where file.pathExtension == "json" {
            let requests = PendingRequestStore(url: file).load()
            combined.merge(requests)
        }
        return combined
    }

    public static func consumeAll(in directory: URL) throws -> PendingRequests {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return PendingRequests()
        }

        let records = files.filter { $0.pathExtension == "json" }.map { ($0, PendingRequestStore(url: $0).load()) }
        // Coalesce ordinary reconciliation requests, but give each explicit Library
        // install its own plan and result, including when several users click at once.
        let oldestSingle = records.filter { $0.1.requestedPackageID != nil }.min {
            ($0.1.runRequestedAt ?? .distantPast) < ($1.1.runRequestedAt ?? .distantPast)
        }
        var combined = PendingRequests()
        for (file, requests) in records {
            if let oldestSingle, requests.runRequestedAt != nil, file != oldestSingle.0 { continue }
            try fileManager.removeItem(at: file)
            combined.merge(requests)
        }
        return combined
    }

    public static func clearStopRequests(in directory: URL) throws {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files where file.pathExtension == "json" {
            let store = PendingRequestStore(url: file)
            var requests = store.load()
            guard requests.stopRequestedAt != nil else { continue }
            requests.stopRequestedAt = nil
            requests.stopRequestID = nil
            if requests.isEmpty {
                try? fileManager.removeItem(at: file)
            } else {
                try store.save(requests)
            }
        }
    }
}

public final class HelperResultStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ result: HelperResult) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: file(for: result.id), options: [.atomic])
    }

    public func loadAll() -> [HelperResult] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(HelperResult.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func file(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }
}

public final class LooperSettingsStore {
    private let url: URL
    private static let managedPreferenceDomain = "com.maxhewett.Looper" as CFString
    public static let managedSettingKeys = [
        "LogRetentionDays",
        "HelperRunMode",
        "RunAppContentSets",
        "AppPackageOverrides",
        "ManagedPreloadEnabled",
        "SkipSetupAssistant",
        "ScheduledInstallEnabled",
        "ScheduleQuietHours",
        "ExcludedPackageIDs",
        "PackagePriorities",
        "NotifyNewLoopsAvailable",
        "NotifyRelaunchPrompts",
        "NotifyRunFailures",
        "NotifyRunSummaries"
    ]

    public init(url: URL) {
        self.url = url
    }

    public func load() -> LooperSettings {
        Self.applyingManagedPreferences(to: loadLocal())
    }

    private func loadLocal() -> LooperSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(LooperSettings.self, from: data) else {
            return LooperSettings()
        }
        return settings
    }

    public func save(_ settings: LooperSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let local = loadLocal()
        let managed = Self.managedKeys()
        var saved = settings
        if managed.contains("RunAppContentSets") { saved.runAppContentSets = local.runAppContentSets }
        if managed.contains("AppPackageOverrides") { saved.appPackageOverrides = local.appPackageOverrides }
        if managed.contains("ExcludedPackageIDs") { saved.excludedPackageIDs = local.excludedPackageIDs }
        if managed.contains("PackagePriorities") { saved.packagePriorities = local.packagePriorities }
        if managed.contains("HelperRunMode") { saved.helperRunMode = local.helperRunMode }
        if managed.contains("LogRetentionDays") { saved.logRetentionDays = local.logRetentionDays }
        if managed.contains("NotifyNewLoopsAvailable") { saved.notifyNewLoopsAvailable = local.notifyNewLoopsAvailable }
        if managed.contains("NotifyRelaunchPrompts") { saved.notifyRelaunchPrompts = local.notifyRelaunchPrompts }
        if managed.contains("NotifyRunFailures") { saved.notifyRunFailures = local.notifyRunFailures }
        if managed.contains("NotifyRunSummaries") { saved.notifyRunSummaries = local.notifyRunSummaries }
        saved.scheduledInstallEnabled = local.scheduledInstallEnabled
        saved.scheduleQuietHours = local.scheduleQuietHours
        try encoder.encode(saved).write(to: url, options: [.atomic])
    }

    public static var skipSetupAssistant: Bool { managedBool("SkipSetupAssistant") == true }

    public static var managedPreloadEnabled: Bool {
        managedBool("ManagedPreloadEnabled") == true && managedAppContentSets("RunAppContentSets")?.isEmpty == false
    }

    public static func managedKeys() -> Set<String> {
        Set(managedSettingKeys.filter { key in
            CFPreferencesAppValueIsForced(key as CFString, managedPreferenceDomain)
        })
    }

    private static func applyingManagedPreferences(to settings: LooperSettings) -> LooperSettings {
        var resolved = settings

        if let days = managedInt("LogRetentionDays") {
            resolved.logRetentionDays = min(365, max(1, days))
        }
        if let value = managedString("HelperRunMode"),
           let mode = LooperHelperRunMode(rawValue: value.lowercased()) {
            resolved.helperRunMode = mode
        }
        if let scope = managedAppContentSets("RunAppContentSets") {
            resolved.runAppContentSets = scope.isEmpty ? ["GarageBand": ["None"], "Logic Pro": ["None"]] : scope
        }
        if let overrides = managedValue("AppPackageOverrides") as? [String: [String: String]] {
            resolved.appPackageOverrides = overrides.mapValues {
                AppPackageOverrides(skip: $0["Skip"] ?? "", only: $0["Only"] ?? "")
            }
        }
        resolved.scheduledInstallEnabled = managedBool("ScheduledInstallEnabled") ?? resolved.scheduledInstallEnabled
        resolved.scheduleQuietHours = managedString("ScheduleQuietHours") ?? resolved.scheduleQuietHours
        if let identifiers = managedStringArray("ExcludedPackageIDs") {
            resolved.excludedPackageIDs = identifiers
        }
        if let priorities = managedPackagePriorities("PackagePriorities") {
            resolved.packagePriorities = priorities
        }
        if let value = managedBool("NotifyNewLoopsAvailable") {
            resolved.notifyNewLoopsAvailable = value
        }
        if let value = managedBool("NotifyRelaunchPrompts") {
            resolved.notifyRelaunchPrompts = value
        }
        if let value = managedBool("NotifyRunFailures") {
            resolved.notifyRunFailures = value
        }
        if let value = managedBool("NotifyRunSummaries") {
            resolved.notifyRunSummaries = value
        }

        return resolved
    }

    private static func managedValue(_ key: String) -> Any? {
        let preferenceKey = key as CFString
        guard CFPreferencesAppValueIsForced(preferenceKey, managedPreferenceDomain) else {
            return nil
        }
        return CFPreferencesCopyAppValue(preferenceKey, managedPreferenceDomain)
    }

    private static func managedString(_ key: String) -> String? {
        managedValue(key) as? String
    }

    private static func managedInt(_ key: String) -> Int? {
        if let number = managedValue(key) as? NSNumber {
            return number.intValue
        }
        if let string = managedString(key) {
            return Int(string)
        }
        return nil
    }

    private static func managedBool(_ key: String) -> Bool? {
        if let number = managedValue(key) as? NSNumber {
            return number.boolValue
        }
        if let string = managedString(key)?.lowercased() {
            switch string {
            case "true", "yes", "1", "enabled": return true
            case "false", "no", "0", "disabled": return false
            default: return nil
            }
        }
        return nil
    }

    private static func managedStringArray(_ key: String) -> [String]? {
        if let values = managedValue(key) as? [String] {
            return values
        }
        if let string = managedString(key) {
            return string
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return nil
    }

    private static func managedPackagePriorities(_ key: String) -> [String: Int]? {
        if let values = managedValue(key) as? [String: Int] {
            return values
        }
        if let values = managedValue(key) as? [String: NSNumber] {
            return values.mapValues(\.intValue)
        }
        if let values = managedValue(key) as? [String: Any] {
            return values.reduce(into: [String: Int]()) { result, item in
                if let number = item.value as? NSNumber {
                    result[item.key] = number.intValue
                } else if let string = item.value as? String, let priority = Int(string) {
                    result[item.key] = priority
                }
            }
        }
        return nil
    }

    private static func managedAppContentSets(_ key: String) -> [String: [String]]? {
        if let dictionary = managedValue(key) as? [String: [String]] {
            return dictionary
        }
        if let dictionary = managedValue(key) as? [String: Any] {
            return dictionary.reduce(into: [String: [String]]()) { result, item in
                if let values = item.value as? [String] {
                    result[item.key] = values
                } else if let string = item.value as? String {
                    result[item.key] = string
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
            }
        }
        return nil
    }
}

public final class LooperEventStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ event: LooperEvent) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let line = try encoder.encode(event) + Data([0x0A])
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: url, options: [.atomic])
            }
            prune(olderThan: LooperSettingsStore(url: LooperPaths().settingsFile).load().logRetentionDays)
        } catch {
            // Event logging is diagnostic only. The helper must never fail a
            // package operation because the event log cannot be updated.
        }
    }

    public func loadRecent(limit: Int = 200, retentionDays: Int? = nil) -> [LooperEvent] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = String(decoding: data, as: UTF8.self)
        let cutoff = retentionDays.flatMap(Self.cutoffDate(for:))
        let events = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? decoder.decode(LooperEvent.self, from: Data(String(line).utf8))
            }
            .filter { event in
                cutoff.map { event.timestamp >= $0 } ?? true
            }
            .sorted { $0.timestamp > $1.timestamp }
        return Array(events.prefix(limit))
    }

    public func prune(olderThan days: Int) {
        guard let cutoff = Self.cutoffDate(for: days),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = String(decoding: data, as: UTF8.self)
        let retained = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let rawLine = String(line)
                guard let event = try? decoder.decode(LooperEvent.self, from: Data(rawLine.utf8)) else {
                    return nil
                }
                return event.timestamp >= cutoff ? rawLine : nil
            }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (retained.joined(separator: "\n") + (retained.isEmpty ? "" : "\n"))
                .data(using: .utf8)?
                .write(to: url, options: [.atomic])
        } catch {
            // Retention is housekeeping. A failure here should not hide logs or
            // interrupt the helper's real work.
        }
    }

    private static func cutoffDate(for days: Int) -> Date? {
        guard days > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }
}

private extension LooperPaths {
    static func userRequestFile(in directory: URL) -> URL {
        let user = NSUserName().isEmpty ? "uid-\(getuid())" : NSUserName()
        let process = ProcessInfo.processInfo.processIdentifier
        return directory.appendingPathComponent("\(user)-\(process).json")
    }
}
