import Foundation

/// Disk-space preflight for loop downloads and installs.
///
/// Apple does not publish reliable package sizes in every catalogue signal we
/// consume, so this combines known catalogue sizes, cached package sizes, and
/// conservative filesystem headroom.
public struct DiskSpacePreflight: Sendable {
    public enum Level: Sendable {
        case ok
        case warning
        case failure
    }

    public var level: Level
    public var message: String
    public var detail: String
    public var availableBytes: Int64?
    public var requiredBytes: Int64?

    public var shouldStop: Bool {
        if case .failure = level {
            return true
        }
        return false
    }
}

public enum DiskSpaceChecker {
    /// Keep a meaningful cushion for the OS, installer expansion, and swap. The
    /// package cache lives on the system volume in the default deployment.
    private static let minimumRunHeadroom: Int64 = 12 * 1_024 * 1_024 * 1_024
    private static let minimumPackageHeadroom: Int64 = 2 * 1_024 * 1_024 * 1_024

    public static func preflightRun(paths: LooperPaths, packages: [LoopPackage]) -> DiskSpacePreflight {
        let available = availableBytes(at: paths.cache)
        if packages.isEmpty {
            return DiskSpacePreflight(level: .ok, message: "No packages need installation.",
                                      detail: "No additional space required.", availableBytes: available, requiredBytes: 0)
        }
        let content = packages.reduce(Int64(0)) { sum, package in
            adding(sum, estimatedRequiredBytes(paths: paths, package: package))
        }
        let required = adding(content, minimumPackageHeadroom)

        guard let available else {
            return DiskSpacePreflight(
                level: .warning,
                message: "Could not check free storage.",
                detail: "Looper could not read available capacity for \(paths.cache.path).",
                availableBytes: nil,
                requiredBytes: required
            )
        }

        if available < required {
            return DiskSpacePreflight(level: .failure, message: "Not enough storage for the selected packages.",
                                      detail: "Free approximately \(formatBytes(required - available)) more or reduce the run scope. Estimated requirement is \(formatBytes(required)), with \(formatBytes(available)) available.",
                                      availableBytes: available, requiredBytes: required)
        }
        if available < minimumRunHeadroom {
            return DiskSpacePreflight(level: .warning, message: "Free storage is low.",
                                      detail: "\(formatBytes(available)) available for an estimated \(formatBytes(required)) requirement.",
                                      availableBytes: available, requiredBytes: required)
        }

        return DiskSpacePreflight(
            level: .ok,
            message: "Storage preflight passed.",
            detail: "\(formatBytes(available)) available for Apple Loop downloads.",
            availableBytes: available,
            requiredBytes: required
        )
    }

    public static func preflightPackage(paths: LooperPaths, package: LoopPackage) -> DiskSpacePreflight {
        let available = availableBytes(at: paths.cache)
        let required = adding(minimumPackageHeadroom, estimatedRequiredBytes(paths: paths, package: package))

        guard let available else {
            return DiskSpacePreflight(
                level: .warning,
                message: "Could not check storage for \(package.displayName).",
                detail: "Looper could not read available capacity for \(paths.cache.path).",
                availableBytes: nil,
                requiredBytes: required
            )
        }

        guard available >= required else {
            return DiskSpacePreflight(
                level: .failure,
                message: "Not enough storage for \(package.displayName).",
                detail: "\(formatBytes(available)) available; \(formatBytes(required)) is required for download and installer working space.",
                availableBytes: available,
                requiredBytes: required
            )
        }

        return DiskSpacePreflight(
            level: .ok,
            message: "Storage check passed for \(package.displayName).",
            detail: "\(formatBytes(available)) available.",
            availableBytes: available,
            requiredBytes: required
        )
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func availableBytes(at url: URL) -> Int64? {
        let probeURL = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let values = try? probeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private static func estimatedRequiredBytes(paths: LooperPaths, package: LoopPackage) -> Int64 {
        let cached = fileSize(at: paths.packageCacheFile(for: package))
        let download = max(0, package.downloadSize ?? 0)
        let expansion = max(0, package.installedSize ?? 0)
        if cached > 0 { return max(cached, expansion) }
        return adding(download, max(download, expansion))
    }

    public static func isOutOfSpace(_ error: Error) -> Bool {
        if case LooperError.insufficientStorage = error { return true }
        if case let LooperError.installFailed(_, message) = error,
           message.localizedCaseInsensitiveContains("no space left on device") { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        return (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { isOutOfSpace($0) } ?? false
    }
}
