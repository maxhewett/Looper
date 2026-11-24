import Foundation

public enum DownloadSource: String, CaseIterable, Sendable {
    case contentCache = "Content cache"
    case web = "Web"
    case local = "On this Mac"
    case unknown = "Unattributed"
}

public struct TransferTotals: Codable, Sendable {
    public var installs = 0
    public var bytes: Int64 = 0
}

/// Local bookkeeping for Looper's last attempt.
///
/// Apple package receipts remain the stronger signal when `pkgIdentifier` is
/// available. This file covers manifest items without known receipts and gives
/// the UI a quick way to report recent failures.
public struct InstallState: Codable, Sendable {
    public var transferTotals: [String: TransferTotals] = [:]
    public var lastCheck: Date?
    public var installedPackages: [String: InstalledPackage]
    public var failedPackages: [String: FailedPackage]
    public var removedPackages: [String: RemovedPackage]
    public var currentRun: InstallRunState?

    public init(
        lastCheck: Date? = nil,
        installedPackages: [String: InstalledPackage] = [:],
        failedPackages: [String: FailedPackage] = [:],
        removedPackages: [String: RemovedPackage] = [:],
        currentRun: InstallRunState? = nil
    ) {
        self.lastCheck = lastCheck
        self.installedPackages = installedPackages
        self.failedPackages = failedPackages
        self.removedPackages = removedPackages
        self.currentRun = currentRun
    }

    public var failureSummary: String? {
        guard !failedPackages.isEmpty else { return nil }
        let count = failedPackages.count
        let names = failedPackages.values.map(\.displayName).sorted().prefix(2).joined(separator: ", ")
        return "\(count) failed package\(count == 1 ? "" : "s") · \(names)\(count > 2 ? " and others" : "")"
    }

    public var attentionDetail: String? {
        let runIssue = currentRun?.needsAttention == true ? currentRun?.message : nil
        let details = [failureSummary, runIssue].compactMap { $0 }
        return details.isEmpty ? nil : details.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case transferTotals
        case lastCheck
        case installedPackages
        case failedPackages
        case removedPackages
        case currentRun
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transferTotals = try container.decodeIfPresent([String: TransferTotals].self, forKey: .transferTotals) ?? [:]
        lastCheck = try container.decodeIfPresent(Date.self, forKey: .lastCheck)
        installedPackages = try container.decodeIfPresent([String: InstalledPackage].self, forKey: .installedPackages) ?? [:]
        failedPackages = try container.decodeIfPresent([String: FailedPackage].self, forKey: .failedPackages) ?? [:]
        for id in LoopPackage.withdrawnIDs { failedPackages.removeValue(forKey: id) }
        removedPackages = try container.decodeIfPresent([String: RemovedPackage].self, forKey: .removedPackages) ?? [:]
        currentRun = try container.decodeIfPresent(InstallRunState.self, forKey: .currentRun)
    }
}

/// Live progress for helper-driven runs.
///
/// The menu bar app watches this file rather than assuming it started the work
/// itself. That keeps progress visible for scheduled and MDM-triggered runs too.
public struct InstallRunState: Codable, Sendable {
    public var isRunning: Bool
    public var needsAttention: Bool?
    public var processID: Int32?
    public var startedAt: Date
    public var overallFraction: Double? {
        guard isRunning, totalPackages > 0, !isStale else { return nil }
        // Installers only report completion. Reserve the last tenth of each
        // package for that step so a completed download does not imply installation.
        var partialPackage = 0.0
        if message.hasPrefix("Installing ") {
            partialPackage = 0.9
        } else if message.hasPrefix("Downloading "), let receivedBytes, let expectedBytes, expectedBytes > 0 {
            partialPackage = 0.9 * min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
        }
        return min(1, max(0, (Double(completedPackages) + partialPackage) / Double(totalPackages)))
    }

    public var overallPercent: Int? {
        overallFraction.map { Int(($0 * 100).rounded(.down)) }
    }

    public var isStale: Bool {
        guard isRunning, Date().timeIntervalSince(updatedAt ?? startedAt) > 180 else { return false }
        guard let processID, processID > 0 else { return true }
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        guard sysctl(&query, 4, &info, &length, nil, 0) == 0, length > 0 else { return true }
        // Persisted dates have second precision. A reused PID belongs to a later process.
        return Double(info.kp_proc.p_starttime.tv_sec) > startedAt.timeIntervalSince1970
    }

    public var finishedAt: Date?
    public var currentPackageID: String?
    public var currentPackageName: String?
    public var message: String
    public var completedPackages: Int
    public var totalPackages: Int
    public var receivedBytes: Int64?
    public var expectedBytes: Int64?
    public var updatedAt: Date?

    public init(
        isRunning: Bool,
        startedAt: Date,
        finishedAt: Date? = nil,
        currentPackageID: String? = nil,
        currentPackageName: String? = nil,
        message: String,
        completedPackages: Int,
        totalPackages: Int,
        receivedBytes: Int64? = nil,
        expectedBytes: Int64? = nil,
        updatedAt: Date? = Date()
    ) {
        self.processID = getpid()
        self.isRunning = isRunning
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.currentPackageID = currentPackageID
        self.currentPackageName = currentPackageName
        self.message = message
        self.completedPackages = completedPackages
        self.totalPackages = totalPackages
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.updatedAt = updatedAt
    }
}

/// Stored after a package install succeeds.
public struct InstalledPackage: Codable, Sendable {
    public var displayName: String
    public var installedAt: Date
    public var pkgIdentifier: String?
}

/// Stored after a package fails so the menu bar UI can show actionable status
/// without parsing historical logs.
public struct FailedPackage: Codable, Sendable {
    public var displayName: String
    public var failedAt: Date
    public var message: String
}

/// Stored when Looper deliberately removes package-owned payload files.
///
/// Some Apple audio package receipts are protected by macOS and can remain
/// visible after the payload is gone. This marker lets Looper treat that content
/// as missing without trying to modify Apple's protected receipt store.
public struct RemovedPackage: Codable, Sendable {
    public var displayName: String
    public var removedAt: Date
    public var pkgIdentifier: String?
}

/// Small JSON state store with stable formatting for easy manual inspection.
public final class StateStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Missing state is normal on first run or after `looper uninstall
    /// --forget-state`.
    public func load() throws -> InstallState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return InstallState()
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(InstallState.self, from: data)
    }

    /// Atomic writes avoid corrupting state if the process is interrupted while
    /// a lab management tool is running Looper in the background.
    public func save(_ state: InstallState) throws {
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }
}
