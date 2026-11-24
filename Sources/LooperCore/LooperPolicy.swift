import Foundation

public struct AppPackageOverrides: Codable, Sendable, Equatable {
    public var skip = ""
    public var only = ""

    var skippedIDs: Set<String> { Self.identifiers(in: skip) }
    var allowedIDs: Set<String> { Self.identifiers(in: only) }

    private static func identifiers(in text: String) -> Set<String> {
        Set(text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }
}

/// A resolved policy describes the content Looper should manage for one run.
///
/// Managed preferences will eventually be the primary source. For now the app,
/// CLI, and helper can construct the same simple value from run controls or
/// request files.
public struct LooperPolicy: Codable, Sendable, Equatable {
    public var targetApps: [String]
    public var contentSets: [String]
    public var appContentSets: [String: [String]]
    public var excludedPackageIDs: Set<String>
    public var packagePriorities: [String: Int]
    public var appPackageOverrides: [String: AppPackageOverrides]?
    public var requestedPackageID: String?
    public var dryRun: Bool

    public init(
        targetApps: [String] = [],
        contentSets: [String] = [],
        appContentSets: [String: [String]] = [:],
        excludedPackageIDs: Set<String> = [],
        packagePriorities: [String: Int] = [:],
        appPackageOverrides: [String: AppPackageOverrides]? = nil,
        dryRun: Bool = false
    ) {
        self.targetApps = targetApps
        self.contentSets = contentSets
        self.appContentSets = appContentSets
        self.excludedPackageIDs = excludedPackageIDs
        self.packagePriorities = packagePriorities
        self.appPackageOverrides = appPackageOverrides
        self.dryRun = dryRun
    }

    public static let all = LooperPolicy()

    public func includes(_ package: LoopPackage, needsUpdate: Bool = false) -> Bool {
        if let requestedPackageID, package.id != requestedPackageID { return false }
        if Self.packageMatchesAnyIdentifier(package, identifiers: excludedPackageIDs) {
            return false
        }

        if !appContentSets.isEmpty || appPackageOverrides?.isEmpty == false {
            return package.targetApps.contains { app in
                let sets: [String]
                if appContentSets.isEmpty {
                    guard targetApps.isEmpty || targetApps.contains(app) else { return false }
                    sets = contentSets
                } else {
                    guard let appSets = appContentSets[app] else { return false }
                    sets = appSets
                }
                guard !sets.contains(where: { $0.caseInsensitiveCompare("None") == .orderedSame }) else {
                    return false
                }
                if let overrides = appPackageOverrides?[app] {
                    if Self.packageMatchesAnyIdentifier(package, identifiers: overrides.skippedIDs) {
                        return false
                    }
                    if !overrides.allowedIDs.isEmpty {
                        return Self.packageMatchesAnyIdentifier(package, identifiers: overrides.allowedIDs)
                    }
                }
                return needsUpdate || Self.packageMatchesAnySet(package, sets: sets, apps: [app])
            }
        }

        let appMatches = targetApps.isEmpty || package.targetApps.contains { targetApps.contains($0) }
        let setMatches = Self.packageMatchesAnySet(package, sets: contentSets, apps: targetApps)
        return appMatches && (setMatches || (needsUpdate && !contentSets.contains(where: { $0.caseInsensitiveCompare("None") == .orderedSame })))
    }

    public func priority(for package: LoopPackage) -> Int {
        if let priority = packagePriorities[package.id] {
            return priority
        }
        if let identifier = package.pkgIdentifier,
           let priority = packagePriorities[identifier] {
            return priority
        }
        return 0
    }

    private static func packageMatchesAnySet(_ package: LoopPackage, sets: [String], apps: [String]) -> Bool {
        guard !sets.isEmpty else { return true }
        if sets.contains(where: { $0.caseInsensitiveCompare("All") == .orderedSame }) {
            return true
        }

        let text = [package.id, package.displayName, package.packageSet ?? "", package.notes ?? ""]
            .joined(separator: " ")
            .lowercased()
        return sets.contains { set in
            let normalisedSet = set.lowercased()
            if normalisedSet == "essential", package.packageSet != nil || package.essentialApps != nil {
                let membership = package.resolvedEssentialApps
                if apps.isEmpty { return !membership.isEmpty || (package.targetApps.isEmpty && package.packageSet == "Essential") }
                return apps.contains(where: membership.contains)
            }
            return text.contains(normalisedSet)
        }
    }

    private static func packageMatchesAnyIdentifier(_ package: LoopPackage, identifiers: Set<String>) -> Bool {
        guard !identifiers.isEmpty else { return false }
        if identifiers.contains(package.id) {
            return true
        }
        if let identifier = package.pkgIdentifier,
           identifiers.contains(identifier) {
            return true
        }
        return false
    }
}
