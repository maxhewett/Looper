import Foundation

/// A manifest is the contract between the brittle Apple discovery layer and the
/// stable installer. If Apple changes where packages are advertised, keep that
/// work in a manifest provider and leave the install pipeline mostly unchanged.
public struct LoopManifest: Codable, Sendable {
    public var version: Int
    public var updated: Date?
    public var packages: [LoopPackage]
}

/// The install mechanism required by a catalogue package.
///
/// Older GarageBand/Logic content ships as installer packages with receipts.
/// Newer Logic content uses Apple Archive payloads plus Logic's Music Apps
/// content database as the installed-state authority.
public enum LoopPackageFormat: String, Codable, Sendable {
    case installerPackage = "pkg"
    case musicAppsArchive = "aar"
}

/// One installable Apple content package.
///
/// `id` is Looper's stable local key. `pkgIdentifier` is Apple's installer
/// receipt id when one is known; it lets us skip content that is already present
/// even if Looper's own state file has been removed.
public struct LoopPackage: Codable, Identifiable, Equatable, Sendable {
    // This retired Logic demo is still advertised in older catalogues, but its archive was withdrawn.
    static let withdrawnIDs: Set<String> = ["arx0007_elliedixon"]

    public var id: String
    public var displayName: String
    public var url: URL
    public var sha256: String?
    public var pkgIdentifier: String?
    public var targetApps: [String]
    public var packageSet: String?
    public var essentialApps: [String]?
    public var fileCheck: String?
    public var downloadSize: Int64?
    public var installedSize: Int64?
    public var packageVersion: String?
    public var contentGroups: [String]?
    public var notes: String?
    public var format: LoopPackageFormat?

    public init(
        id: String,
        displayName: String,
        url: URL,
        sha256: String? = nil,
        pkgIdentifier: String? = nil,
        targetApps: [String] = [],
        packageSet: String? = nil,
        essentialApps: [String]? = nil,
        fileCheck: String? = nil,
        downloadSize: Int64? = nil,
        installedSize: Int64? = nil,
        packageVersion: String? = nil,
        contentGroups: [String]? = nil,
        notes: String? = nil,
        format: LoopPackageFormat? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.sha256 = sha256
        self.pkgIdentifier = pkgIdentifier
        self.targetApps = targetApps
        self.packageSet = packageSet
        self.essentialApps = essentialApps
        self.fileCheck = fileCheck
        self.downloadSize = downloadSize
        self.installedSize = installedSize
        self.packageVersion = packageVersion
        self.contentGroups = contentGroups
        self.notes = notes
        self.format = format
    }

    public var resolvedEssentialApps: [String] {
        if let essentialApps { return essentialApps }
        // Older Apple catalogue caches retained the source app in the merged notes.
        let sources = targetApps.filter { app in
            ["Essential Apple catalogue package for ", "Essential Apple app catalogue package for "]
                .contains { notes?.contains($0 + app + ".") == true }
        }
        if !sources.isEmpty { return sources }
        return packageSet?.lowercased() == "essential" ? targetApps : []
    }

    public var installFormat: LoopPackageFormat {
        if let format {
            return format
        }
        return url.pathExtension.localizedCaseInsensitiveCompare("aar") == .orderedSame
            ? .musicAppsArchive
            : .installerPackage
    }

    /// Apple's catalogues use `FileCheck` as the quick payload-presence test
    /// shown in GarageBand and Logic Pro. Empty strings are common enough in
    /// ad-hoc captures that callers should treat them as absent.
    public var normalisedFileCheckPath: String? {
        guard let path = fileCheck?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }
}

/// Compares Apple's catalogue package version against receipt versions.
///
/// Receipts often add build/install metadata after the meaningful package
/// version. For example, a catalogue may advertise `3.000000` while the receipt
/// records `3.0.0.0.1.1602785573`; comparing the components advertised in the catalogue avoids
/// reinstalling current content forever while still catching real catalogue
/// version bumps.
public enum ApplePackageVersion {
    public static func installedVersion(_ installedVersion: String?, satisfiesCatalogueVersion catalogueVersion: String?) -> Bool {
        guard let catalogueVersion,
              !catalogueVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        guard let installedVersion,
              !installedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let width = max(1, components(from: catalogueVersion).count)
        return compare(installedVersion, catalogueVersion, width: width) != .orderedAscending
    }

    public static func newerCatalogueVersion(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return compare(lhs, rhs, width: max(components(from: lhs).count, components(from: rhs).count)) == .orderedAscending ? rhs : lhs
    }

    private static func compare(_ lhs: String, _ rhs: String, width: Int) -> ComparisonResult {
        let lhsComponents = paddedComponents(from: lhs, width: width)
        let rhsComponents = paddedComponents(from: rhs, width: width)
        for (lhs, rhs) in zip(lhsComponents, rhsComponents) {
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func paddedComponents(from version: String, width: Int) -> [Int] {
        var values = components(from: version)
        while values.count < width {
            values.append(0)
        }
        return Array(values.prefix(width))
    }

    private static func components(from version: String) -> [Int] {
        let normalised = version.map { character -> Character in
            character.isNumber ? character : "."
        }
        return String(normalised)
            .split(separator: ".")
            .compactMap { Int($0) }
    }
}

public enum ManifestLoader {
    /// Load a manifest from disk. Lab deployments usually copy this into
    /// `/Library/Application Support/Looper/loops.json`, but tests and one-off
    /// investigations can point the CLI at any file.
    public static func load(from url: URL) throws -> LoopManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(LoopManifest.self, from: data)
        manifest.packages.removeAll { LoopPackage.withdrawnIDs.contains($0.id) }
        return manifest
    }

    /// Save a manifest using stable key ordering so catalogue changes are easy
    /// to review in source control or management tooling.
    public static func save(_ manifest: LoopManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }
}
