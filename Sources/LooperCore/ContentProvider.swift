import Foundation

/// A provider owns the brittle knowledge for one Apple content delivery flow.
///
/// Apple loop package installs are the first supported provider. GarageBand and
/// Logic Pro share the current plist-driven package catalogue, while future
/// Logic-only flows can still be added behind another provider if Apple changes
/// delivery again.
public protocol ContentProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    func discoverCatalogue() -> LoopManifest
    func detectInstalledContent(in manifest: LoopManifest) -> InstalledContent
}

/// Provider-level installed-state evidence for a catalogue snapshot.
public struct InstalledContent: Sendable {
    public var updatePackageIDs: Set<String> = []
    public var installedPackageIDs: Set<String>
    public var installedReceiptIdentifiers: Set<String>

    public init(
        installedPackageIDs: Set<String> = [],
        installedReceiptIdentifiers: Set<String> = []
    ) {
        self.installedPackageIDs = installedPackageIDs
        self.installedReceiptIdentifiers = installedReceiptIdentifiers
    }

    public func contains(_ package: LoopPackage) -> Bool {
        if installedPackageIDs.contains(package.id) {
            return true
        }
        if let receipt = package.pkgIdentifier {
            return installedReceiptIdentifiers.contains(receipt)
        }
        return false
    }
}

/// Apple's current loop provider reads the GarageBand and Logic Pro package
/// catalogues, then uses Apple audio package receipts plus Apple's own
/// `FileCheck` paths as the installed content signal.
///
/// We avoid calling `pkgutil --files` for every package during planning because
/// that makes a simple refresh feel hung on machines with a full loop library.
/// Apple catalogue file checks are cheap and catch repair/update cases where a
/// receipt exists but the package payload is incomplete.
public struct AppleAudioPackageProvider: ContentProvider {
    public let id = "apple-audio-packages"
    public let displayName = "Apple Audio Packages"

    private let packageInstaller: PackageInstaller
    private let manifestURL: URL
    private let musicAppsStore: MusicAppsContentStore

    public init(
        packageInstaller: PackageInstaller = PackageInstaller(),
        manifestURL: URL = LooperPaths.defaultManifestURL,
        musicAppsStore: MusicAppsContentStore = MusicAppsContentStore()
    ) {
        self.packageInstaller = packageInstaller
        self.manifestURL = manifestURL
        self.musicAppsStore = musicAppsStore
    }

    public func discoverCatalogue() -> LoopManifest {
        AppleContentDiscovery.loadAppleOrManagedManifest(from: manifestURL, musicAppsStore: musicAppsStore)
    }

    public func detectInstalledContent(in manifest: LoopManifest) -> InstalledContent {
        let receipts = packageInstaller.installedAppleAudioContent()
        let installedReceipts = Set(receipts.map(\.identifier))
        let receiptVersions = Dictionary(uniqueKeysWithValues: receipts.compactMap { receipt -> (String, String)? in
            guard let version = receipt.packageVersion else { return nil }
            return (receipt.identifier, version)
        })
        let musicAppsInstalledIDs = musicAppsStore.installedPackageIDs(in: manifest.packages)
        let installedPackageIDs = manifest.packages.reduce(into: Set<String>()) { packageIDs, package in
            guard isInstalled(
                package,
                installedReceipts: installedReceipts,
                receiptVersions: receiptVersions,
                musicAppsInstalledIDs: musicAppsInstalledIDs
            ) else {
                return
            }
            packageIDs.insert(package.id)
        }
        let validatedReceipts = Set(manifest.packages.compactMap { package -> String? in
            guard let receipt = package.pkgIdentifier,
                  installedReceipts.contains(receipt),
                  isInstalled(
                      package,
                      installedReceipts: installedReceipts,
                      receiptVersions: receiptVersions,
                      musicAppsInstalledIDs: musicAppsInstalledIDs
                  ) else {
                return nil
            }
            return receipt
        })

        var content = InstalledContent(installedPackageIDs: installedPackageIDs, installedReceiptIdentifiers: validatedReceipts)
        let logicUpdates = musicAppsStore.sharedUpdateCandidates()
        for package in manifest.packages where !content.contains(package) {
            let hasReceipt = package.pkgIdentifier.map(installedReceipts.contains) ?? false
            let hasPayload = package.normalisedFileCheckPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            if hasReceipt || hasPayload || (package.installFormat == .musicAppsArchive && logicUpdates.contains(package.id)) {
                content.updatePackageIDs.insert(package.id)
            }
        }
        return content
    }

    private func isInstalled(
        _ package: LoopPackage,
        installedReceipts: Set<String>,
        receiptVersions: [String: String],
        musicAppsInstalledIDs: Set<String>
    ) -> Bool {
        if package.installFormat == .musicAppsArchive {
            return musicAppsInstalledIDs.contains(package.id)
        }

        if let fileCheck = package.normalisedFileCheckPath {
            guard FileManager.default.fileExists(atPath: fileCheck) else {
                return false
            }
        }

        guard let receipt = package.pkgIdentifier else {
            return package.normalisedFileCheckPath != nil
        }
        guard installedReceipts.contains(receipt) else {
            return false
        }
        return ApplePackageVersion.installedVersion(
            receiptVersions[receipt],
            satisfiesCatalogueVersion: package.packageVersion
        )
    }
}

public typealias GarageBandPackageProvider = AppleAudioPackageProvider
