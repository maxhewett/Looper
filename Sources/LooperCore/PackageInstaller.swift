import Foundation

/// A package receipt discovered from Apple's installer database.
///
/// These records let Looper report content that was installed by GarageBand,
/// Logic Pro, Munki, Jamf, or another management path before Looper existed on
/// the machine.
public struct InstalledAppleContentReceipt: Sendable {
    public var identifier: String
    public var displayName: String
    public var targetApps: [String]
    public var packageSet: String
    public var packageVersion: String?

    public init(
        identifier: String,
        displayName: String,
        targetApps: [String],
        packageSet: String,
        packageVersion: String? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.targetApps = targetApps
        self.packageSet = packageSet
        self.packageVersion = packageVersion
    }
}

public struct PackageDeletionSummary: Sendable {
    public var identifier: String
    public var removedFiles: Int
    public var removedDirectories: Int
    public var skippedPaths: [String]
}

private struct ProcessResult {
    var status: Int32
    var output: String
    var errorOutput: String
}

/// Thin wrapper around Apple's command-line installer tools.
///
/// Keeping this separate makes it easier to test or replace later if we need a
/// privileged helper tool, MDM-specific path, or app-bundle embedded helper.
public struct PackageInstaller: Sendable {
    public init() {}

    /// Return installed Apple audio-content receipts from `pkgutil`.
    ///
    /// The current Apple packages use names such as
    /// `com.apple.pkg.MAContent10_AssetPack_0615_GBLogicAlchemyEssentials`.
    /// We keep the parser conservative so unknown future names still appear in
    /// the UI rather than disappearing because the friendly-name logic lagged
    /// behind Apple's catalogue.
    public func installedAppleAudioContent() -> [InstalledAppleContentReceipt] {
        guard let output = try? runPkgutil(arguments: ["--pkgs"], timeout: 15) else {
            return []
        }
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter(Self.isAppleAudioReceipt)
            .map { identifier in
                Self.receipt(from: identifier, packageVersion: receiptPackageVersion(identifier: identifier))
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Prefer Apple's receipt database when the manifest has a receipt id. It is
    /// more reliable than checking for loop folders, because content locations
    /// and folder names have changed across GarageBand and Logic releases.
    public func isInstalled(_ package: LoopPackage) -> Bool {
        guard let identifier = package.pkgIdentifier, !identifier.isEmpty else { return false }
        guard receiptExists(identifier) else { return false }
        guard receiptVersionSatisfiesCatalogue(identifier: identifier, catalogueVersion: package.packageVersion) else {
            return false
        }
        return packageHasInstalledPayload(identifier: identifier)
    }

    public func receiptVersionSatisfiesCatalogue(identifier: String, catalogueVersion: String?) -> Bool {
        ApplePackageVersion.installedVersion(receiptPackageVersion(identifier: identifier), satisfiesCatalogueVersion: catalogueVersion)
    }

    /// Install to the system volume. This generally requires administrative
    /// privileges when run outside a management context.
    public func install(pkg: URL) throws {
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/usr/sbin/installer"),
            arguments: ["-pkg", pkg.path, "-target", "/"],
            timeout: 1_800
        )

        guard result.status == 0 else {
            throw LooperError.installFailed(status: result.status, message: result.errorOutput)
        }
    }

    /// Remove the files owned by a package receipt, then forget the receipt.
    ///
    /// This is intentionally conservative. Only known Apple audio-content roots
    /// are eligible for removal, and shared parent folders are left alone unless
    /// they are empty and safely beneath those roots.
    public func deletePackageContent(identifier: String, progress: ((String) -> Void)? = nil) throws -> PackageDeletionSummary {
        progress?("Checking installed Apple audio receipts.")
        guard installedAppleAudioContent().contains(where: { $0.identifier == identifier }) else {
            throw LooperError.packageNotInstalled(identifier)
        }

        progress?("Reading package install location.")
        let location = try packageInstallLocation(identifier: identifier)
        progress?("Reading package payload paths.")
        let payloadPaths = try packagePayloadPaths(identifier: identifier, location: location)
        let fileManager = FileManager.default
        var removedFiles = 0
        var removedDirectories = 0
        var directories: [URL] = []
        var skipped: [String] = []

        for path in payloadPaths {
            guard isAllowedAudioContentPath(path) else {
                skipped.append(path.path)
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                directories.append(path)
            } else {
                try fileManager.removeItem(at: path)
                removedFiles += 1
                if removedFiles == 1 || removedFiles.isMultiple(of: 50) {
                    progress?("Removed \(removedFiles) files.")
                }
            }
        }

        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            guard isRemovableAudioContentDirectory(directory),
                  (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true else {
                continue
            }
            try fileManager.removeItem(at: directory)
            removedDirectories += 1
        }

        progress?("Forgetting package receipt.")
        try forgetPackage(identifier: identifier)
        if receiptExists(identifier) {
            progress?("Apple protected receipt remains; Looper will track the removal locally.")
        }
        progress?("Delete finished.")
        return PackageDeletionSummary(
            identifier: identifier,
            removedFiles: removedFiles,
            removedDirectories: removedDirectories,
            skippedPaths: skipped
        )
    }

    public func packagePayloadPaths(identifier: String, location: URL) throws -> [URL] {
        let output = try runPkgutil(arguments: ["--files", identifier])
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { location.appendingPathComponent($0) }
    }

    /// Return existing payload paths from the receipt. The UI uses this for
    /// Finder reveal without needing elevated privileges or hard-coded loop
    /// folder guesses.
    public func existingPayloadPaths(identifier: String) throws -> [URL] {
        let location = try packageInstallLocation(identifier: identifier)
        return try packagePayloadPaths(identifier: identifier, location: location)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func packageHasInstalledPayload(identifier: String) -> Bool {
        (try? existingPayloadPaths(identifier: identifier).isEmpty == false) ?? false
    }

    private static func receipt(from identifier: String, packageVersion: String?) -> InstalledAppleContentReceipt {
        let suffix = identifier
            .replacingOccurrences(of: "com.apple.pkg.", with: "")
            .replacingOccurrences(of: "MAContent10_AssetPack_", with: "")
            .replacingOccurrences(of: "MAContent10_", with: "")
        let nameWithoutNumber = suffix.drop { $0.isNumber || $0 == "_" }
        let compactName = String(nameWithoutNumber).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let displayName = friendlyName(from: compactName)

        return InstalledAppleContentReceipt(
            identifier: identifier,
            displayName: displayName.isEmpty ? identifier : displayName,
            targetApps: targetApps(from: compactName),
            packageSet: packageSet(from: compactName),
            packageVersion: packageVersion
        )
    }

    private static func isAppleAudioReceipt(_ identifier: String) -> Bool {
        let knownPrefixes = [
            "com.apple.pkg.MAContent10_AssetPack_",
            "com.apple.pkg.MAContent10_",
            "com.apple.pkg.GarageBand",
            "com.apple.pkg.JamPack",
            "com.apple.pkg.RemixTools",
            "com.apple.pkg.RhythmSection",
            "com.apple.pkg.SymphonyOrchestra",
            "com.apple.pkg.WorldMusic"
        ]
        if knownPrefixes.contains(where: { identifier.hasPrefix($0) }) {
            return true
        }

        // Older Logic/GarageBand content packages use exact instrument-suite
        // receipt names such as `Voices_Instruments` rather than the MAContent
        // prefixes used by the current catalogue.
        let legacyInstrumentSuites = [
            "com.apple.pkg.JamPack4_Instruments",
            "com.apple.pkg.RemixTools_Instruments",
            "com.apple.pkg.RhythmSection_Instruments",
            "com.apple.pkg.Voices_Instruments",
            "com.apple.pkg.WorldMusic_Instruments"
        ]
        return legacyInstrumentSuites.contains(identifier)
    }

    private func packageInstallLocation(identifier: String) throws -> URL {
        let output = try runPkgutil(arguments: ["--pkg-info", identifier])
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard line.hasPrefix("location:") else { continue }
            let path = line
                .replacingOccurrences(of: "location:", with: "")
                .trimmingCharacters(in: .whitespaces)
            return URL(fileURLWithPath: path.isEmpty ? "/" : path, isDirectory: true)
        }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    private func receiptPackageVersion(identifier: String) -> String? {
        if let version = receiptPackageVersionFromPlist(identifier: identifier) {
            return version
        }

        guard let output = try? runPkgutil(arguments: ["--pkg-info", identifier], timeout: 15) else {
            return nil
        }
        for line in output.split(whereSeparator: \.isNewline).map(String.init) where line.hasPrefix("version:") {
            return line
                .replacingOccurrences(of: "version:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func receiptPackageVersionFromPlist(identifier: String) -> String? {
        for url in receiptPropertyListURLs(identifier: identifier) {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dictionary = plist as? [String: Any] else {
                continue
            }
            if let version = dictionary["PackageVersion"] as? String {
                return version
            }
            if let version = dictionary["PackageVersion"] as? NSNumber {
                return version.stringValue
            }
        }
        return nil
    }

    private func receiptPropertyListURLs(identifier: String) -> [URL] {
        [
            URL(fileURLWithPath: "/Library/Apple/System/Library/Receipts", isDirectory: true),
            URL(fileURLWithPath: "/Library/Receipts", isDirectory: true)
        ].map { directory in
            directory.appendingPathComponent(identifier).appendingPathExtension("plist")
        }
    }

    private func forgetPackage(identifier: String) throws {
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/usr/sbin/pkgutil"),
            arguments: ["--forget", identifier],
            timeout: 30
        )

        guard result.status == 0 else {
            throw LooperError.deleteFailed(identifier: identifier, message: "pkgutil --forget exited with status \(result.status). \(result.errorOutput)")
        }
    }

    private func receiptExists(_ identifier: String) -> Bool {
        (try? runPkgutil(arguments: ["--pkg-info", identifier], timeout: 15)) != nil
    }

    private func runPkgutil(arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/usr/sbin/pkgutil"),
            arguments: arguments,
            timeout: timeout
        )

        guard result.status == 0 else {
            throw LooperError.deleteFailed(identifier: arguments.last ?? "unknown", message: "pkgutil exited with status \(result.status). \(result.errorOutput)")
        }

        return result.output
    }

    private func runProcess(executable: URL, arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("looper-\(UUID().uuidString)")
            .appendingPathExtension("out")
        let errorURL = fileManager.temporaryDirectory
            .appendingPathComponent("looper-\(UUID().uuidString)")
            .appendingPathExtension("err")
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        fileManager.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)

        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }

        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning {
                process.interrupt()
            }
            throw LooperError.deleteFailed(
                identifier: arguments.last ?? executable.lastPathComponent,
                message: "\(executable.lastPathComponent) timed out after \(Int(timeout)) seconds."
            )
        }

        try outputHandle.synchronize()
        try errorHandle.synchronize()
        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: (try? Data(contentsOf: outputURL)) ?? Data(), as: UTF8.self),
            errorOutput: String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self)
        )
    }

    private func isAllowedAudioContentPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/Library/Application Support/Logic/")
            || path.hasPrefix("/Library/Application Support/GarageBand/")
            || path.hasPrefix("/Library/Audio/Apple Loops/")
    }

    private func isRemovableAudioContentDirectory(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let protected = [
            "/Library/Application Support/Logic",
            "/Library/Application Support/GarageBand",
            "/Library/Audio/Apple Loops"
        ]
        return isAllowedAudioContentPath(url) && !protected.contains(path)
    }

    private static func targetApps(from compactName: String) -> [String] {
        if compactName.contains("GBLogic") {
            return ["GarageBand", "Logic Pro"]
        }
        if compactName.contains("GB") || compactName.contains("GarageBand") {
            return ["GarageBand"]
        }
        if compactName.contains("Logic") || compactName.contains("LTP") || compactName.contains("EXS") {
            return ["Logic Pro"]
        }
        return ["GarageBand", "Logic Pro"]
    }

    private static func packageSet(from compactName: String) -> String {
        let lowercased = compactName.lowercased()
        if lowercased.contains("essential") || lowercased.contains("basic") {
            return "Essential"
        }
        return "All"
    }

    private static func friendlyName(from compactName: String) -> String {
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
}
