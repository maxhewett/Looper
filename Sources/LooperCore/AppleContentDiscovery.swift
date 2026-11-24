import Foundation

/// Builds a Looper catalogue from Apple-managed audio content signals.
///
/// Apple's loop delivery currently exposes app-specific property lists on the
/// audio-content CDN. Those plists are a better availability source than local
/// receipts, because they include content that is not installed yet.
public enum AppleContentDiscovery {
    /// Current GarageBand/Logic package CDN path observed in captured installs.
    ///
    /// Keep this in one place because Apple has changed content delivery before.
    /// Catalogue providers can replace it when a better app database source is
    /// available.
    public static let observedPackageBaseURL = URL(string: "https://audiocontentdownload.apple.com/lp10_ms3_content_2016/")!
    public static let observedCatalogueBaseURL = URL(string: "https://audiocontentdownload.apple.com/lp10_ms3_content_2016/")!

    public static let defaultCatalogueSeeds = [
        AppleLoopCatalogueSeed(appName: "GarageBand", fileStem: "garageband", seedVersion: 1047),
        AppleLoopCatalogueSeed(appName: "Logic Pro", fileStem: "logicpro", seedVersion: 1100)
    ]

    public static let defaultAppCatalogueSeeds = [
        AppleAppBundleCatalogueSeed(
            appName: "GarageBand",
            appURL: URL(fileURLWithPath: "/Applications/GarageBand.app", isDirectory: true),
            fileStem: "garageband"
        ),
        AppleAppBundleCatalogueSeed(
            appName: "Logic Pro",
            appURL: URL(fileURLWithPath: "/Applications/Logic Pro.app", isDirectory: true),
            fileStem: "logicpro"
        )
    ]

    static func uniquePackages(_ packages: [LoopPackage]) -> [LoopPackage] {
        AppleLoopCatalogueClient.mergePackages(packages)
    }

    /// Ask Apple's loop catalogues for every package currently advertised.
    ///
    /// Each app has a numbered plist such as `garageband1047.plist`. Apple can
    /// publish a higher number without changing the base CDN path, so discovery
    /// probes ahead from the known seed and uses the highest available version.
    public static func appleCatalogueManifest(
        baseURL: URL = observedCatalogueBaseURL,
        seeds: [AppleLoopCatalogueSeed] = defaultCatalogueSeeds,
        musicAppsStore: MusicAppsContentStore = MusicAppsContentStore(),
        session: URLSession = .shared
    ) throws -> LoopManifest {
        let client = AppleLoopCatalogueClient(baseURL: baseURL, session: session)
        var manifests: [LoopManifest] = []
        if let onlineManifest = try? client.manifest(for: seeds) {
            manifests.append(onlineManifest)
        }
        if let bundledManifest = try? bundledAppCatalogueManifest(packageBaseURL: observedPackageBaseURL) {
            manifests.append(bundledManifest)
        }
        if let musicAppsManifest = try? musicAppsStore.catalogueManifest(refreshIncrements: true) {
            manifests.append(musicAppsManifest)
        }

        let packages = AppleLoopCatalogueClient.mergePackages(manifests.flatMap(\.packages))
        guard !packages.isEmpty else {
            throw LooperError.catalogueUnavailable("Apple loop catalogues did not contain any packages.")
        }

        return LoopManifest(
            version: manifests.map(\.version).max() ?? 1,
            updated: manifests.compactMap(\.updated).max(),
            packages: packages.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        )
    }

    public static func musicAppsCatalogueManifest(store: MusicAppsContentStore = MusicAppsContentStore()) throws -> LoopManifest {
        try store.catalogueManifest()
    }

    public static func discoveredReceiptManifest(
        receipts: [InstalledAppleContentReceipt] = PackageInstaller().installedAppleAudioContent(),
        packageBaseURL: URL = observedPackageBaseURL
    ) -> LoopManifest {
        let packages = receipts.map { receipt in
            let assetName = receipt.identifier.replacingOccurrences(of: "com.apple.pkg.", with: "")
            return LoopPackage(
                id: assetName,
                displayName: receipt.displayName,
                url: packageBaseURL.appendingPathComponent("\(assetName).pkg"),
                sha256: nil,
                pkgIdentifier: receipt.identifier,
                targetApps: receipt.targetApps,
                packageSet: receipt.packageSet,
                packageVersion: receipt.packageVersion,
                notes: "Discovered from an Apple package receipt. Looper did not install this package."
            )
        }

        return LoopManifest(version: 1, updated: Date(), packages: packages)
    }

    public static func bundledAppCatalogueManifest(
        seeds: [AppleAppBundleCatalogueSeed] = defaultAppCatalogueSeeds,
        packageBaseURL: URL = observedPackageBaseURL
    ) throws -> LoopManifest {
        let packageList = seeds.flatMap { seed in
            AppleAppBundleCatalogueClient(packageBaseURL: packageBaseURL).packages(for: seed)
        }
        let mergedPackages = AppleLoopCatalogueClient.mergePackages(packageList)

        guard !mergedPackages.isEmpty else {
            throw LooperError.catalogueUnavailable("Installed Apple apps did not contain usable loop catalogues.")
        }

        return LoopManifest(
            version: 1,
            updated: Date(),
            packages: mergedPackages.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        )
    }

    public static func loadManagedOrDiscoveredManifest(
        from url: URL = LooperPaths.defaultManifestURL,
        musicAppsStore: MusicAppsContentStore = MusicAppsContentStore()
    ) -> LoopManifest {
        if let managed = try? ManifestLoader.load(from: url) {
            return managed
        }
        if let appleCatalogue = try? appleCatalogueManifest(musicAppsStore: musicAppsStore) {
            return appleCatalogue
        }
        if let musicAppsCatalogue = try? musicAppsCatalogueManifest(store: musicAppsStore) {
            return musicAppsCatalogue
        }
        if let bundledCatalogue = try? bundledAppCatalogueManifest() {
            return bundledCatalogue
        }
        return discoveredReceiptManifest()
    }

    public static func loadAppleOrManagedManifest(
        from url: URL = LooperPaths.defaultManifestURL,
        musicAppsStore: MusicAppsContentStore = MusicAppsContentStore()
    ) -> LoopManifest {
        if let appleCatalogue = try? appleCatalogueManifest(musicAppsStore: musicAppsStore) {
            return appleCatalogue
        }
        if let musicAppsCatalogue = try? musicAppsCatalogueManifest(store: musicAppsStore) {
            return musicAppsCatalogue
        }
        if let bundledCatalogue = try? bundledAppCatalogueManifest() {
            return bundledCatalogue
        }
        if let managed = try? ManifestLoader.load(from: url) {
            return managed
        }
        return discoveredReceiptManifest()
    }
}

public struct AppleLoopCatalogueSeed: Sendable {
    public var appName: String
    public var fileStem: String
    public var seedVersion: Int

    public init(appName: String, fileStem: String, seedVersion: Int) {
        self.appName = appName
        self.fileStem = fileStem
        self.seedVersion = seedVersion
    }
}

public struct AppleAppBundleCatalogueSeed: Sendable {
    public var appName: String
    public var appURL: URL
    public var fileStem: String

    public init(appName: String, appURL: URL, fileStem: String) {
        self.appName = appName
        self.appURL = appURL
        self.fileStem = fileStem
    }
}

private struct AppleAppBundleCatalogueClient {
    private let packageBaseURL: URL

    init(packageBaseURL: URL) {
        self.packageBaseURL = packageBaseURL
    }

    func packages(for seed: AppleAppBundleCatalogueSeed) -> [LoopPackage] {
        guard let catalogueURL = newestCatalogueURL(for: seed),
              let data = try? Data(contentsOf: catalogueURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let packageDictionaries = root["Packages"] as? [String: [String: Any]] else {
            return []
        }

        let groupsByPackage = contentGroupsByPackage(from: root["Content"])
        return packageDictionaries.compactMap { packageID, packageInfo in
            package(from: packageInfo, fallbackPackageID: packageID, appName: seed.appName, groups: groupsByPackage[packageID] ?? [])
        }
    }

    private func newestCatalogueURL(for seed: AppleAppBundleCatalogueSeed) -> URL? {
        let resourcesURL = seed.appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: resourcesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return files
            .filter { $0.pathExtension == "plist" && $0.deletingPathExtension().lastPathComponent.hasPrefix(seed.fileStem) }
            .sorted { lhs, rhs in
                catalogueVersion(from: lhs, stem: seed.fileStem) > catalogueVersion(from: rhs, stem: seed.fileStem)
            }
            .first
    }

    private func catalogueVersion(from url: URL, stem: String) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: stem, with: "")) ?? 0
    }

    private func package(
        from packageInfo: [String: Any],
        fallbackPackageID: String,
        appName: String,
        groups: [String]
    ) -> LoopPackage? {
        guard let downloadName = packageInfo["DownloadName"] as? String,
              let packageURL = packageURL(from: downloadName) else {
            return nil
        }

        let identifier = (packageInfo["PackageID"] as? String) ?? "com.apple.pkg.\(fallbackPackageID)"
        let packageID = identifier.replacingOccurrences(of: "com.apple.pkg.", with: "")
        let compactName = AppleLoopCatalogueClient.compactName(from: packageID)
        let displayName = AppleLoopCatalogueClient.friendlyName(from: compactName)
        let isEssential = ((packageInfo["IsMandatory"] as? Bool) ?? false)
            || ((packageInfo["IsEssentialAddition"] as? Bool) ?? false)
            || groups.contains { $0.localizedCaseInsensitiveContains("Essential") }
        let packageSet = isEssential ? "Essential" : "All"
        let contentGroups = Array(Set(groups)).sorted()
        let notes = [
            "\(packageSet) Apple app catalogue package for \(appName).",
            contentGroups.isEmpty ? nil : "Groups: \(contentGroups.joined(separator: ", "))"
        ]
            .compactMap { $0 }
            .joined(separator: " ")

        return LoopPackage(
            id: packageID,
            displayName: displayName.isEmpty ? packageID : displayName,
            url: packageURL,
            sha256: nil,
            pkgIdentifier: identifier,
            targetApps: AppleLoopCatalogueClient.targetApps(for: appName, compactName: compactName),
            packageSet: packageSet,
            essentialApps: packageSet == "Essential" ? [appName] : [],
            fileCheck: packageInfo["FileCheck"] as? String,
            downloadSize: int64Value(packageInfo["DownloadSize"]),
            installedSize: int64Value(packageInfo["InstalledSize"]),
            packageVersion: stringValue(packageInfo["PackageVersion"]),
            contentGroups: contentGroups.isEmpty ? nil : contentGroups,
            notes: notes
        )
    }

    private func packageURL(from downloadName: String) -> URL? {
        if let absolute = URL(string: downloadName), absolute.scheme != nil {
            return absolute
        }
        return URL(string: downloadName, relativeTo: packageBaseURL)?.absoluteURL
    }

    private func contentGroupsByPackage(from content: Any?) -> [String: [String]] {
        var groupsByPackage: [String: Set<String>] = [:]

        func walk(_ value: Any?, inheritedGroup: String?) {
            if let dictionary = value as? [String: Any] {
                if let english = dictionary["en"] {
                    walk(english, inheritedGroup: inheritedGroup)
                    return
                }
                if dictionary.keys.allSatisfy({ $0.count <= 5 }),
                   let firstLocaleValue = dictionary.values.first {
                    walk(firstLocaleValue, inheritedGroup: inheritedGroup)
                    return
                }

                let groupName = displayName(from: dictionary) ?? dictionary["Name"] as? String ?? inheritedGroup
                if let packages = dictionary["Packages"] as? [String] {
                    for package in packages {
                        groupsByPackage[package, default: []].insert(groupName ?? "Ungrouped")
                    }
                }
                walk(dictionary["Content"], inheritedGroup: groupName)
                walk(dictionary["SubContent"], inheritedGroup: groupName)
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    walk(item, inheritedGroup: inheritedGroup)
                }
            }
        }

        walk(content, inheritedGroup: nil)
        return groupsByPackage.mapValues { Array($0).sorted() }
    }

    private func displayName(from dictionary: [String: Any]) -> String? {
        guard let localisable = dictionary["_LOCALIZABLE_"] as? [[String: Any]] else {
            return nil
        }
        return localisable.compactMap { $0["DisplayName"] as? String }.first
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let integer = value as? Int {
            return Int64(integer)
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}

private struct AppleLoopCatalogueClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    func manifest(for seeds: [AppleLoopCatalogueSeed]) throws -> LoopManifest {
        let packageList = try seeds.flatMap { seed in
            try packages(for: seed)
        }
        let mergedPackages = Self.mergePackages(packageList)

        guard !mergedPackages.isEmpty else {
            throw LooperError.catalogueUnavailable("Apple loop catalogues did not contain any packages.")
        }

        return LoopManifest(
            version: 1,
            updated: Date(),
            packages: mergedPackages.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        )
    }

    private func packages(for seed: AppleLoopCatalogueSeed) throws -> [LoopPackage] {
        let plistURL = try highestAvailableCatalogueURL(for: seed)
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = plist as? [String: Any],
              let packageDictionaries = root["Packages"] as? [String: [String: Any]] else {
            throw LooperError.catalogueUnavailable("Apple catalogue \(plistURL.lastPathComponent) does not have a Packages dictionary.")
        }

        return packageDictionaries.compactMap { _, packageInfo in
            package(from: packageInfo, appName: seed.appName)
        }
    }

    private func highestAvailableCatalogueURL(for seed: AppleLoopCatalogueSeed) throws -> URL {
        var bestVersion = seed.seedVersion
        var missCount = 0
        var version = seed.seedVersion + 1

        while missCount < 25 {
            let candidate = catalogueURL(stem: seed.fileStem, version: version)
            if try urlExists(candidate) {
                bestVersion = version
                missCount = 0
            } else {
                missCount += 1
            }
            version += 1
        }

        return catalogueURL(stem: seed.fileStem, version: bestVersion)
    }

    private func catalogueURL(stem: String, version: Int) -> URL {
        baseURL.appendingPathComponent("\(stem)\(version).plist")
    }

    private func package(from packageInfo: [String: Any], appName: String) -> LoopPackage? {
        guard let downloadName = packageInfo["DownloadName"] as? String,
              let packageURL = packageURL(from: downloadName) else {
            return nil
        }

        let identifier = (packageInfo["PackageID"] as? String)
            ?? "com.apple.pkg.\(packageURL.deletingPathExtension().lastPathComponent)"
        let packageID = identifier.replacingOccurrences(of: "com.apple.pkg.", with: "")
        let compactName = Self.compactName(from: packageID)
        let displayName = Self.friendlyName(from: compactName)
        let isMandatory = (packageInfo["IsMandatory"] as? Bool) ?? false
        let packageSet = isMandatory ? "Essential" : "All"

        return LoopPackage(
            id: packageID,
            displayName: displayName.isEmpty ? packageID : displayName,
            url: packageURL,
            sha256: nil,
            pkgIdentifier: identifier,
            targetApps: Self.targetApps(for: appName, compactName: compactName),
            packageSet: packageSet,
            essentialApps: packageSet == "Essential" ? [appName] : [],
            fileCheck: packageInfo["FileCheck"] as? String,
            downloadSize: int64Value(packageInfo["DownloadSize"]),
            installedSize: int64Value(packageInfo["InstalledSize"]),
            packageVersion: stringValue(packageInfo["PackageVersion"]),
            notes: "\(packageSet) Apple catalogue package for \(appName)."
        )
    }

    private func packageURL(from downloadName: String) -> URL? {
        if let absolute = URL(string: downloadName), absolute.scheme != nil {
            return absolute
        }
        return URL(string: downloadName, relativeTo: baseURL)?.absoluteURL
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let integer = value as? Int {
            return Int64(integer)
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func urlExists(_ url: URL) throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8

        let semaphore = DispatchSemaphore(value: 0)
        var exists: Bool?
        let task = session.dataTask(with: request) { _, response, _ in
            if let status = (response as? HTTPURLResponse)?.statusCode {
                exists = (200..<300).contains(status)
            }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 10) == .success, let exists else {
            task.cancel()
            throw LooperError.catalogueUnavailable("Could not reach the Apple catalogue server.")
        }
        return exists
    }

    static func targetApps(for appName: String, compactName: String) -> [String] {
        if compactName.contains("GBLogic") {
            return ["GarageBand", "Logic Pro"]
        }
        if compactName.contains("MainStage") {
            return ["MainStage"]
        }
        return [appName]
    }

    static func mergePackages(_ packages: [LoopPackage]) -> [LoopPackage] {
        var mergedByID: [String: LoopPackage] = [:]

        for package in packages {
            let key = package.pkgIdentifier ?? package.id
            guard var existing = mergedByID[key] else {
                mergedByID[key] = package
                continue
            }

            existing.essentialApps = Array(Set(existing.resolvedEssentialApps + package.resolvedEssentialApps)).sorted()
            existing.targetApps = Array(Set(existing.targetApps + package.targetApps)).sorted()
            existing.packageSet = mergedPackageSet(existing.packageSet, package.packageSet)
            existing.fileCheck = existing.fileCheck ?? package.fileCheck
            existing.downloadSize = maxValue(existing.downloadSize, package.downloadSize)
            existing.installedSize = maxValue(existing.installedSize, package.installedSize)
            existing.packageVersion = ApplePackageVersion.newerCatalogueVersion(existing.packageVersion, package.packageVersion)
            let contentGroups = Array(Set((existing.contentGroups ?? []) + (package.contentGroups ?? []))).sorted()
            existing.contentGroups = contentGroups.isEmpty ? nil : contentGroups
            let notes = [existing.notes, package.notes]
                .compactMap { $0 }
                .flatMap { $0.components(separatedBy: "; ") }
            existing.notes = Array(Set(notes)).sorted().joined(separator: "; ")
            mergedByID[key] = existing
        }

        return Array(mergedByID.values)
    }

    static func compactName(from assetName: String) -> String {
        let withoutKnownPrefixes = assetName
            .replacingOccurrences(of: "MAContent10_AssetPack_", with: "")
            .replacingOccurrences(of: "MAContent10_", with: "")
            .replacingOccurrences(of: "_Instruments", with: " Instruments")
        return withoutKnownPrefixes
            .drop { $0.isNumber || $0 == "_" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    static func friendlyName(from compactName: String) -> String {
        let withoutAppSuffix = compactName
            .replacingOccurrences(of: "GBLogic", with: "")
            .replacingOccurrences(of: "GarageBand", with: "GarageBand ")
        let withExpandedPrefixes = withoutAppSuffix
            .replacingOccurrences(of: "EXS_", with: "EXS ")
            .replacingOccurrences(of: "UB_", with: "Ultrabeat ")
            .replacingOccurrences(of: "LTP", with: "Lesson ")

        let spaced = withExpandedPrefixes.reduce(into: "") { result, character in
            if character == "_" {
                result.append(" ")
            } else if character.isUppercase,
                      let previous = result.last,
                      previous.isLowercase || previous.isNumber {
                result.append(" ")
                result.append(character)
            } else {
                result.append(character)
            }
        }

        return spaced
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mergedPackageSet(_ lhs: String?, _ rhs: String?) -> String? {
        if lhs == "Essential" || rhs == "Essential" {
            return "Essential"
        }
        return lhs ?? rhs
    }

    private static func maxValue(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            return max(lhs, rhs)
        case let (.some(value), .none), let (.none, .some(value)):
            return value
        case (.none, .none):
            return nil
        }
    }
}
