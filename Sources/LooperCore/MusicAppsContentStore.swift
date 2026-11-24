import Foundation
import Darwin

/// Reads and finalises Logic's newer Music Apps content packages.
///
/// Logic 12 advertises many sound packs through `ContentDatabaseV01.db`; those
/// packs are Apple Archives (`.aar`) rather than installer packages. Installing
/// them requires both copying the archive payload into the Logic library bundle
/// and marking the package/items available in the same database Logic reads.
public struct MusicAppsContentStore: Sendable {
    private static let bundledDatabase = URL(fileURLWithPath:
        "/Applications/Logic Pro.app/Contents/Resources/Library.bundle/ContentDatabaseV02.db/index.db")
    public static let sharedLibrary = URL(fileURLWithPath:
        "/Library/Application Support/Looper/Logic Pro Library.bundle", isDirectory: true)

    public init() {
        if FileManager.default.fileExists(atPath: Self.bundledDatabase.path) {
            self.init(databaseURL: Self.bundledDatabase, libraryURL: Self.sharedLibrary)
        } else {
            self.init(userHomeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    public static let defaultDatabaseURL = URL(
        fileURLWithPath: "~/Music/Audio Music Apps/Databases/ContentDatabaseV01.db/index.db".expandingTilde
    )
    public static let defaultLibraryURL = URL(
        fileURLWithPath: "~/Music/Logic Pro Library.bundle".expandingTilde,
        isDirectory: true
    )
    public static let defaultContentPackBaseURL = URL(
        string: "https://audiocontentdownload.apple.com/universal/ContentPacks_3/"
    )!

    public static func defaultDatabaseURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Music/Audio Music Apps/Databases/ContentDatabaseV01.db", isDirectory: true)
            .appendingPathComponent("index.db")
    }

    public static func defaultLibraryURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Music/Logic Pro Library.bundle", isDirectory: true)
    }

    private let databaseURL: URL
    private let libraryURL: URL
    private let contentPackBaseURL: URL
    private let ownerUserID: uid_t?
    private let ownerGroupID: gid_t?

    public init(
        userHomeDirectory: URL,
        ownerUserID: Int? = nil,
        ownerGroupID: Int? = nil,
        contentPackBaseURL: URL = Self.defaultContentPackBaseURL
    ) {
        self.init(
            databaseURL: Self.defaultDatabaseURL(homeDirectory: userHomeDirectory),
            libraryURL: Self.defaultLibraryURL(homeDirectory: userHomeDirectory),
            contentPackBaseURL: contentPackBaseURL,
            ownerUserID: ownerUserID,
            ownerGroupID: ownerGroupID
        )
    }

    public init(
        databaseURL: URL,
        libraryURL: URL = Self.defaultLibraryURL,
        contentPackBaseURL: URL = Self.defaultContentPackBaseURL,
        ownerUserID: Int? = nil,
        ownerGroupID: Int? = nil
    ) {
        self.databaseURL = databaseURL
        self.libraryURL = libraryURL
        self.contentPackBaseURL = contentPackBaseURL
        self.ownerUserID = ownerUserID.map(uid_t.init)
        self.ownerGroupID = ownerGroupID.map(gid_t.init)
    }

    public func catalogueManifest(refreshIncrements: Bool = false) throws -> LoopManifest {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw LooperError.catalogueUnavailable("Music Apps database was not found at \(databaseURL.path).")
        }

        let rows = try sqliteRows("""
            select ZIDENTIFIER,
                   coalesce(nullif(ZLOCALIZEDDISPLAYNAME, ''), nullif(ZDISPLAYNAME, ''), ZIDENTIFIER),
                   ZSERVERPATH,
                   coalesce(ZSERVERVERSION, 0),
                   coalesce(ZDOWNLOADSIZE, 0),
                   coalesce(ZINSTALLEDSIZE, 0)
            from ZPACKAGE
            where ZSERVERPATH like '%.aar'
              and coalesce(ZDOWNLOADSIZE, 0) > 0
            order by ZIDENTIFIER;
            """)

        var byID = Dictionary(rows.compactMap(package(from:)).map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        if databaseURL == Self.bundledDatabase {
            for change in catalogueIncrements(refresh: refreshIncrements) {
                if let existing = byID[change.id], (Int(existing.packageVersion ?? "") ?? 0) > (Int(change.packageVersion ?? "") ?? 0) { continue }
                byID[change.id] = change
            }
        }
        let packages = byID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        guard !packages.isEmpty else {
            throw LooperError.catalogueUnavailable("Music Apps database did not contain installable archive packages.")
        }
        return LoopManifest(version: 1, updated: Date(), packages: packages)
    }

    // Logic 13's bundled V02 database uses the V4 catalogue stream. Apple
    // publishes ordered deltas relative to its ShippingContentVersion.
    private func catalogueIncrements(refresh: Bool) -> [LoopPackage] {
        let fm = FileManager.default
        let versionFile = databaseURL.deletingLastPathComponent().appendingPathComponent("ShippingContentVersion")
        guard let text = try? String(contentsOf: versionFile, encoding: .utf8),
              let base = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), base >= 0, base < 9999 else { return [] }
        let shared = LooperPaths().cache.appendingPathComponent("LogicCatalogueV4")
        let writable = geteuid() == 0 ? shared : fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.maxhewett.Looper/LogicCatalogueV4")
        let origin = "https://audiocontentdownload.apple.com/universal/"
        var latest = base
        if refresh, let data = try? runToolData("/usr/bin/curl", arguments: ["-fsS", "--max-time", "8", origin + "contentversion.plist"], capturesOutput: true),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           info["incrementalFormat"] as? String == "aar", let version = info["contentversionV4"] as? Int {
            latest = min(version, 9999)
        }
        var updates: [LoopPackage] = []
        for version in (base + 1)...9999 {
            let name = String(format: "contentDB_v%04d", version)
            let cached = [shared, writable].lazy.compactMap { folder -> [LoopPackage]? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name + ".plist")) else { return nil }
                return self.incrementPackages(data)
            }.first
            if let cached {
                updates.append(contentsOf: cached)
                continue
            }
            guard refresh, version <= latest else { break }
            let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: temp) }
            do {
                try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let archive = temp.appendingPathComponent("catalogue.aar")
                _ = try runTool("/usr/bin/curl", arguments: ["-fsS", "--max-time", "90", "-o", archive.path, origin + name + ".aar"])
                let entry = name + ".bundle/Package.plist"
                _ = try runTool("/usr/bin/aa", arguments: ["extract", "-i", archive.path, "-d", temp.path, "-include-path", entry])
                let data = try Data(contentsOf: temp.appendingPathComponent(entry))
                guard let packages = incrementPackages(data) else { break }
                try fm.createDirectory(at: writable, withIntermediateDirectories: true)
                try data.write(to: writable.appendingPathComponent(name + ".plist"), options: .atomic)
                updates.append(contentsOf: packages)
            } catch { break }
        }
        return updates
    }

    private func incrementPackages(_ data: Data) -> [LoopPackage]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let records = plist["attributes"] as? [[String: Any]] else { return nil }
        return records.compactMap { record in
            guard let id = record["identifier"] as? String, let path = record["serverPath"] as? String,
                  let version = record["serverVersion"] as? Int, let size = record["downloadSize"] as? Int64,
                  size > 0, path.hasSuffix(".aar"), !path.hasPrefix("/"),
                  path.range(of: #"^[A-Za-z0-9_/.-]+$"#, options: .regularExpression) != nil,
                  !path.split(separator: "/").contains(".."),
                  id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            let name = record["localizedDisplayName"] as? String ?? record["displayName"] as? String ?? id
            return package(from: [id, name, path, String(version), String(size), String(record["installedSize"] as? Int64 ?? 0)])
        }
    }

    /// Browse Packs can offer an update when Logic recognises partial or legacy
    /// content. Use that hint only for the signed-in user's selected shared library.
    public static func logicUpdatesForSharedLibrary() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bookmark = home.appendingPathComponent("Library/Application Support/com.apple.musicapps.content/Logic Pro Library.bookmark")
        var stale = false
        guard geteuid() != 0, let data = try? Data(contentsOf: bookmark),
              let selected = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
              selected.standardizedFileURL.path == sharedLibrary.path else { return [] }
        let index = home.appendingPathComponent("Music/Audio Music Apps/Databases/ContentDatabaseV02.db/index.db")
        let store = Self(databaseURL: index, libraryURL: sharedLibrary)
        guard let rows = try? store.sqliteRows("""
            select ZIDENTIFIER from ZPACKAGE
            where ZSERVERPATH like '%.aar' and (ZINSTALLEDVERSION = -2
                or (ZINSTALLEDVERSION >= 0 and ZINSTALLEDVERSION < ZSERVERVERSION));
            """) else { return [] }
        return Set(rows.compactMap(\.first))
    }

    func sharedUpdateCandidates() -> Set<String> {
        guard libraryURL == Self.sharedLibrary else { return [] }
        let folder = libraryURL.appendingPathComponent("Application Support/Package Definitions")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var ids = Set(files.compactMap { url -> String? in
            guard url.pathExtension == "plist", let data = try? Data(contentsOf: url),
                  let receipt = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return receipt["Bundle Identifier"] as? String
        })
        if geteuid() != 0 { return ids.union(Self.logicUpdatesForSharedLibrary()) }

        // Query each Logic index as its owner, including for unattended lab runs.
        // Only identifiers from the independently discovered catalogue can enter the plan.
        let homes = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Users"),
                                                                  includingPropertiesForKeys: nil)) ?? []
        for home in homes {
            let index = home.appendingPathComponent("Music/Audio Music Apps/Databases/ContentDatabaseV02.db/index.db")
            var info = stat()
            guard FileManager.default.fileExists(atPath: index.path), lstat(home.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid >= 500,
                  let account = getpwuid(info.st_uid), String(cString: account.pointee.pw_dir) == home.path else { continue }
            let args = ["-n", "-H", "-u", "#\(info.st_uid)", "--",
                        "/Library/PrivilegedHelperTools/" + LooperPaths.deviceHelperLabel, "logic-update-ids"]
            if let output = try? runTool("/usr/bin/sudo", arguments: args, capturesOutput: true) {
                ids.formUnion(output.split(separator: "\n").map(String.init))
            }
        }
        return ids
    }

    public func installedPackageIDs(in packages: [LoopPackage]? = nil) -> Set<String> {
        if libraryURL == Self.sharedLibrary {
            guard let candidates = packages ?? (try? catalogueManifest().packages) else { return [] }
            return Set(candidates.filter { $0.installFormat == .musicAppsArchive }.compactMap { package in
                let receipt = definitionURL(for: package, in: libraryURL)
                return validDefinition(receipt, package: package, root: libraryURL) ? package.id : nil
            })
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let rows = try? sqliteRows("""
                select ZIDENTIFIER
                from ZPACKAGE
                where ZSERVERPATH like '%.aar'
                  and ZSERVERVERSION >= 0
                  and ZINSTALLEDVERSION >= ZSERVERVERSION;
                """) else {
            return []
        }
        return Set(rows.compactMap(\.first))
    }

    public func install(archive: URL, package: LoopPackage, workDirectory: URL) throws {
        let stagingURL = workDirectory
            .appendingPathComponent("musicapps-\(package.id)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        _ = try runTool("/usr/bin/aa", arguments: ["extract", "-i", archive.path, "-d", stagingURL.path])
        let payload = extractedPayloadRoot(in: stagingURL)
        if libraryURL == Self.sharedLibrary {
            try installSharedPayload(payload, package: package)
            return
        }
        let details = try packageDetails(identifier: package.id)
        try mergeDirectory(from: payload, into: libraryURL)
        try writePackageDefinition(for: details)
        try finaliseInstalledState(for: details)
    }

    private func definitionURL(for package: LoopPackage, in root: URL) -> URL {
        root.appendingPathComponent("Application Support/Package Definitions")
            .appendingPathComponent(package.url.deletingPathExtension().lastPathComponent + ".plist")
    }

    private func validDefinition(_ url: URL, package: LoopPackage, root: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let receipt = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              receipt["Bundle Identifier"] as? String == package.id,
              let version = receipt["PackageVersion"] as? Int,
              version >= (Int(package.packageVersion ?? "1") ?? 1),
              let checks = receipt["FileChecks"] as? [String], !checks.isEmpty else { return false }
        return checks.allSatisfy { path in
            !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
                && FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
    }

    private func installSharedPayload(_ payload: URL, package: LoopPackage) throws {
        let fm = FileManager.default
        let receipt = definitionURL(for: package, in: payload)
        guard validDefinition(receipt, package: package, root: payload) else {
            throw LooperError.catalogueUnavailable("Apple’s archive failed the package or payload checks for \(package.displayName).")
        }
        try fm.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var traversalError: Error?
        guard let files = fm.enumerator(at: payload, includingPropertiesForKeys: keys, errorHandler: { _, error in
            traversalError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        for case let source as URL in files {
            if source.path == receipt.path { continue }
            let relative = String(source.path.dropFirst(payload.path.count + 1))
            let target = libraryURL.appendingPathComponent(relative)
            let values = try source.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw LooperError.catalogueUnavailable("Unsupported archive entry: \(relative)")
            }
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            } else {
                // Move each complete staged file into place. The cache and library
                // reside on the system data volume.
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
                guard rename(source.path, target.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        if let traversalError { throw traversalError }
        guard validDefinition(receipt, package: package, root: libraryURL) else {
            throw LooperError.catalogueUnavailable("Installed files failed Apple’s checks for \(package.displayName).")
        }
        try Data(contentsOf: receipt).write(to: definitionURL(for: package, in: libraryURL), options: .atomic)
    }

    /// Logic persists the selected library as Foundation bookmark data, including
    /// its file identity. Replacing the default directory invalidates that identity.
    public static func connectSharedLibrary() throws {
        let fm = FileManager.default
        guard geteuid() != 0, fm.fileExists(atPath: bundledDatabase.path),
              fm.fileExists(atPath: sharedLibrary.path) else { return }
        let local = defaultLibraryURL(homeDirectory: fm.homeDirectoryForCurrentUser)
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("com.apple.musicapps.content")
        let bookmark = folder.appendingPathComponent("Logic Pro Library.bookmark")
        if fm.fileExists(atPath: bookmark.path) {
            let data = try Data(contentsOf: bookmark)
            var stale = false
            if let selected = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                       relativeTo: nil, bookmarkDataIsStale: &stale) {
                if selected.standardizedFileURL.path == sharedLibrary.path, !stale {
                    try recordProvisionedEssentials()
                    return
                }
                guard [sharedLibrary.path, local.path].contains(selected.standardizedFileURL.path) else { return }
            } else {
                let values = NSURL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)
                let original = values?[.pathKey] as? String
                guard original == local.path || original == sharedLibrary.path else { return }
            }
        }
        let previousLink = (try? fm.destinationOfSymbolicLink(atPath: local.path)) == sharedLibrary.path
        if !previousLink, fm.fileExists(atPath: local.path) {
            let children = try fm.contentsOfDirectory(atPath: local.path)
            guard children.isEmpty, (try? fm.destinationOfSymbolicLink(atPath: local.path)) == nil else { return }
        }
        let data = try sharedLibrary.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: bookmark, options: .atomic)
        try recordProvisionedEssentials()
    }

    private static let onboardingPackIDs: Set<String> = [
        "ecp0001_essentialhiphop", "ecp0002_essentialelectronic", "ecp0003_essentialinstruments"
    ]

    private static func recordProvisionedEssentials() throws {
        let domain = "com.apple.logic10" as CFString
        let key = "recommendedDownloadWasShownPreviously" as CFString
        guard !CFPreferencesGetAppBooleanValue(key, domain, nil) else { return }
        let store = MusicAppsContentStore(databaseURL: bundledDatabase, libraryURL: sharedLibrary)
        let packs = try store.catalogueManifest().packages.filter { onboardingPackIDs.contains($0.id) }
        guard Set(packs.map(\.id)) == onboardingPackIDs, packs.allSatisfy({ pack in
            store.validDefinition(store.definitionURL(for: pack, in: sharedLibrary), package: pack, root: sharedLibrary)
        }) else { return }
        CFPreferencesSetAppValue(key, kCFBooleanTrue, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw CocoaError(.fileWriteUnknown) }
    }

    public func fileCheckURL(for package: LoopPackage) -> URL? {
        guard let path = try? firstFileCheckPath(identifier: package.id) else {
            return nil
        }
        return libraryURL.appendingPathComponent(path)
    }

    private func package(from row: [String]) -> LoopPackage? {
        guard row.count >= 6,
              let url = URL(string: row[2], relativeTo: contentPackBaseURL)?.absoluteURL else {
            return nil
        }
        let identifier = row[0]
        guard !LoopPackage.withdrawnIDs.contains(identifier) else { return nil }
        let displayName = row[1].isEmpty ? identifier : row[1]
        return LoopPackage(
            id: identifier,
            displayName: displayName,
            url: url,
            sha256: nil,
            pkgIdentifier: nil,
            targetApps: ["Logic Pro"],
            packageSet: packageSet(identifier: identifier, displayName: displayName),
            fileCheck: nil,
            downloadSize: Int64(row[4]),
            installedSize: Int64(row[5]),
            packageVersion: row[3],
            notes: "Logic Music Apps archive package.",
            format: .musicAppsArchive
        )
    }

    private func packageDetails(identifier: String) throws -> MusicAppsPackageDetails {
        let fields = try sqliteRows("""
            select Z_PK,
                   ZIDENTIFIER,
                   coalesce(nullif(ZLOCALIZEDDISPLAYNAME, ''), nullif(ZDISPLAYNAME, ''), ZIDENTIFIER),
                   ZSERVERPATH,
                   coalesce(ZSERVERVERSION, 0),
                   coalesce(ZDOWNLOADSIZE, 0),
                   coalesce(ZINSTALLEDSIZE, 0)
            from ZPACKAGE
            where ZIDENTIFIER = \(sqlLiteral(identifier))
            limit 1;
            """).first
        guard let fields, fields.count >= 7 else {
            throw LooperError.catalogueUnavailable("No Music Apps package named \(identifier) was found.")
        }

        let rowID = fields[0]
        return MusicAppsPackageDetails(
            rowID: rowID,
            identifier: fields[1],
            displayName: fields[2],
            serverPath: fields[3],
            serverVersion: Int(fields[4]) ?? 0,
            downloadSize: Int64(fields[5]) ?? 0,
            installedSize: Int64(fields[6]) ?? 0,
            fileChecks: try fileChecks(rowID: rowID)
        )
    }

    private func fileChecks(rowID: String) throws -> [String] {
        try sqliteRows("""
            select ZITEM.ZFILEPATH
            from ZITEM
            join Z_3PACKAGES on ZITEM.Z_PK = Z_3PACKAGES.Z_3ITEMS1
            where Z_3PACKAGES.Z_4PACKAGES = \(rowID)
              and ZITEM.ZFILEPATH is not null
              and ZITEM.ZFILEPATH != ''
            order by ZITEM.ZFILEPATH;
            """)
            .compactMap(\.first)
            .map(normalisedFileCheck)
    }

    private func firstFileCheckPath(identifier: String) throws -> String? {
        let rows = try sqliteRows("""
            select ZITEM.ZFILEPATH
            from ZITEM
            join Z_3PACKAGES on ZITEM.Z_PK = Z_3PACKAGES.Z_3ITEMS1
            where Z_3PACKAGES.Z_4PACKAGES = (select Z_PK from ZPACKAGE where ZIDENTIFIER = \(sqlLiteral(identifier)))
              and ZITEM.ZFILEPATH like 'ADDI_CNT/%'
              and ZITEM.ZFILEPATH is not null
              and ZITEM.ZFILEPATH != ''
            order by ZITEM.ZAVAILABLE desc, ZITEM.ZFILEPATH
            limit 1;
            """)
        return rows.first?.first.map(payloadRelativePath)
    }

    private func extractedPayloadRoot(in stagingURL: URL) -> URL {
        let addiContentURL = stagingURL.appendingPathComponent("ADDI_CNT", isDirectory: true)
        if FileManager.default.fileExists(atPath: addiContentURL.path) {
            return addiContentURL
        }
        return stagingURL
    }

    private func mergeDirectory(from source: URL, into destination: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        while let item = enumerator.nextObject() as? URL {
            let relativePath = String(item.path.dropFirst(source.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }

            let targetURL = destination.appendingPathComponent(relativePath)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
                applyTargetOwnership(to: targetURL)
                continue
            }

            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            applyTargetOwnership(to: targetURL.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: item, to: targetURL)
            applyTargetOwnership(to: targetURL)
        }
    }

    private func writePackageDefinition(for package: MusicAppsPackageDetails) throws {
        let definitionsURL = libraryURL.appendingPathComponent("Application Support/Package Definitions", isDirectory: true)
        try FileManager.default.createDirectory(at: definitionsURL, withIntermediateDirectories: true)

        let propertyList: [String: Any] = [
            "Bundle Identifier": package.identifier,
            "Bundle Name": package.displayName,
            "DownloadName": package.serverPath,
            "DownloadSize": package.downloadSize,
            "InstalledSize": package.installedSize,
            "PackageVersion": package.serverVersion,
            "Revision": currentRevision(),
            "FileChecks": package.fileChecks
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        let fileName = URL(fileURLWithPath: package.serverPath).deletingPathExtension().lastPathComponent
        applyTargetOwnership(to: definitionsURL)
        let definitionURL = definitionsURL.appendingPathComponent(fileName).appendingPathExtension("plist")
        try data.write(to: definitionURL, options: [.atomic])
        applyTargetOwnership(to: definitionURL)
    }

    private func finaliseInstalledState(for package: MusicAppsPackageDetails) throws {
        let installedDate = Int(Date().timeIntervalSinceReferenceDate)
        _ = try runTool("/usr/bin/sqlite3", arguments: [databaseURL.path, """
            BEGIN IMMEDIATE;
            update ZPACKAGE
               set ZINSTALLEDVERSION = ZSERVERVERSION,
                   ZINSTALLEDDATE = \(installedDate),
                   Z_OPT = Z_OPT + 1
             where ZIDENTIFIER = \(sqlLiteral(package.identifier));
            update ZITEM
               set ZAVAILABLE = 1,
                   ZINSTALLEDDATE = \(installedDate),
                   Z_OPT = Z_OPT + 1
             where Z_PK in (
                   select Z_3ITEMS1
                     from Z_3PACKAGES
                    where Z_4PACKAGES = \(package.rowID)
             );
            COMMIT;
            """])
        repairDatabaseSidecarOwnership()
    }

    /// Use one representative Logic browser tag per pack so grouping never duplicates a row.
    static func browseCategories() -> [String: String] {
        let index = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Audio Music Apps/Databases/ContentDatabaseV02.db/index.db")
        var categories: [String: String] = [:]
        for database in [bundledDatabase, index] where FileManager.default.fileExists(atPath: database.path) {
            let store = Self(databaseURL: database)
            let rows = (try? store.sqliteRows("""
                with labels as (
                 select p.ZIDENTIFIER id,c.ZIDENTIFIER category,t.ZLABEL label,count(*) votes
                 from ZCATEGORY c join ZTAG t on t.ZCATEGORY=c.Z_PK
                 join ZTAGGING g on g.ZTAG=t.Z_PK join Z_3TAGGINGS b on b.Z_6TAGGINGS=g.Z_PK
                 join Z_3PACKAGES a on a.Z_3ITEMS1=b.Z_3ITEMS join ZPACKAGE p on p.Z_PK=a.Z_4PACKAGES
                 where c.ZIDENTIFIER in ('Genres','Content Type') and t.ZLABEL is not null
                 group by p.Z_PK,c.Z_PK,t.ZLABEL
                ), ranked as (
                 select *, row_number() over(partition by id order by votes desc, case when label='Demo Song' then 0 when category='Genres' then 1 else 2 end,label) rank
                 from labels
                )
                select id,label from ranked where rank=1;
                """)) ?? []
            for row in rows where row.count == 2 { categories[row[0]] = row[1] }
        }
        return categories
    }

    private func sqliteRows(_ sql: String) throws -> [[String]] {
        let output = try runTool(
            "/usr/bin/sqlite3",
            arguments: ["-readonly", "-separator", "\u{1F}", databaseURL.path, sql],
            capturesOutput: true
        )
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            }
    }

    private func runTool(_ launchPath: String, arguments: [String], capturesOutput: Bool = false) throws -> String {
        let data = try runToolData(launchPath, arguments: arguments, capturesOutput: capturesOutput)
        return String(decoding: data, as: UTF8.self)
    }

    private func runToolData(_ launchPath: String, arguments: [String], capturesOutput: Bool) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        if capturesOutput {
            process.standardOutput = stdout
        }
        process.standardError = stderr

        try process.run()
        let captured = capturesOutput ? stdout.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw LooperError.installFailed(status: process.terminationStatus, message: stderrText)
        }

        return captured
    }

    private func packageSet(identifier: String, displayName: String) -> String {
        if Self.onboardingPackIDs.contains(identifier) { return "Essential" }
        let lowercased = "\(identifier) \(displayName)".lowercased()
        return lowercased.contains("essential") ? "Essential" : "All"
    }

    private func normalisedFileCheck(_ path: String) -> String {
        "./\(payloadRelativePath(path))"
    }

    private func payloadRelativePath(_ path: String) -> String {
        path.hasPrefix("ADDI_CNT/") ? String(path.dropFirst("ADDI_CNT/".count)) : path
    }

    private func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func currentRevision() -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return Int(formatter.string(from: Date())) ?? 0
    }

    private func applyTargetOwnership(to url: URL) {
        guard let ownerUserID else { return }
        chown(url.path, ownerUserID, ownerGroupID ?? gid_t.max)
    }

    private func repairDatabaseSidecarOwnership() {
        applyTargetOwnership(to: databaseURL)
        applyTargetOwnership(to: databaseURL.deletingLastPathComponent())
        for suffix in ["-wal", "-shm", "-journal"] {
            applyTargetOwnership(to: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }
}

private struct MusicAppsPackageDetails {
    var rowID: String
    var identifier: String
    var displayName: String
    var serverPath: String
    var serverVersion: Int
    var downloadSize: Int64
    var installedSize: Int64
    var fileChecks: [String]
}

private extension String {
    var expandingTilde: String {
        NSString(string: self).expandingTildeInPath
    }
}
