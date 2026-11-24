import Foundation

/// A concrete package action chosen for a reconcile run.
public enum ReconcileAction: String, Codable, Sendable {
    case install
    case skip
}

public struct ReconcilePlanEntry: Codable, Identifiable, Sendable {
    public var id: String { package.id }
    public var package: LoopPackage
    public var action: ReconcileAction
    public var reason: String

    public init(package: LoopPackage, action: ReconcileAction, reason: String) {
        self.package = package
        self.action = action
        self.reason = reason
    }
}

/// The immutable plan for one run.
///
/// The helper should eventually persist this before doing work, so an admin can
/// tell why each package was installed, skipped, or ignored.
public struct ReconcilePlan: Codable, Sendable {
    public var id: String
    public var createdAt: Date
    public var providerID: String
    public var providerName: String
    public var policy: LooperPolicy
    public var entries: [ReconcilePlanEntry]

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        providerID: String,
        providerName: String,
        policy: LooperPolicy,
        entries: [ReconcilePlanEntry]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.providerID = providerID
        self.providerName = providerName
        self.policy = policy
        self.entries = entries
    }

    public var installCount: Int {
        entries.filter { $0.action == .install }.count
    }

    public var skipCount: Int {
        entries.filter { $0.action == .skip }.count
    }
}

public enum ReconcilePlanner {
    public static func build(
        provider: ContentProvider,
        policy: LooperPolicy,
        existingState: InstallState
    ) -> ReconcilePlan {
        let manifest = provider.discoverCatalogue()
        let installedContent = provider.detectInstalledContent(in: manifest)
        let entries = manifest.packages.enumerated().compactMap { index, package -> (Int, ReconcilePlanEntry)? in
            let update = installedContent.updatePackageIDs.contains(package.id) && !wasMarkedRemoved(package, in: existingState)
            guard policy.includes(package, needsUpdate: update) else {
                return nil
            }

            if wasMarkedRemoved(package, in: existingState) {
                return (index, ReconcilePlanEntry(
                    package: package,
                    action: .install,
                    reason: "Removed by Looper; reinstall requested by policy."
                ))
            }

            if installedContent.contains(package) {
                return (index, ReconcilePlanEntry(
                    package: package,
                    action: .skip,
                    reason: "Installed payload detected by \(provider.displayName)."
                ))
            }

            if package.pkgIdentifier == nil,
               package.installFormat != .musicAppsArchive,
               existingState.installedPackages[package.id] != nil {
                return (index, ReconcilePlanEntry(
                    package: package,
                    action: .skip,
                    reason: "Installed by previous Looper run."
                ))
            }

            return (index, ReconcilePlanEntry(
                package: package,
                action: .install,
                reason: update ? "Update existing content to the catalogue version." : "Missing from provider installed-state detection."
            ))
        }
        .sorted { lhs, rhs in
            let lhsPriority = policy.priority(for: lhs.1.package)
            let rhsPriority = policy.priority(for: rhs.1.package)
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }
            return lhs.0 < rhs.0
        }
        .map(\.1)

        return ReconcilePlan(
            providerID: provider.id,
            providerName: provider.displayName,
            policy: policy,
            entries: entries
        )
    }

    private static func wasMarkedRemoved(_ package: LoopPackage, in state: InstallState) -> Bool {
        if state.removedPackages[package.id] != nil {
            return true
        }

        guard let receipt = package.pkgIdentifier else {
            return false
        }

        return state.removedPackages.values.contains { $0.pkgIdentifier == receipt }
    }
}
