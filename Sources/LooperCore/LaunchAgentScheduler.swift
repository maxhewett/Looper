import Foundation

public struct LaunchAgentStatus: Sendable {
    public var isInstalled: Bool
    public var plistURL: URL
    public var interval: TimeInterval?
    public var arguments: [String]
}

/// Manages the per-user scheduled Looper run used by the app while developing.
///
/// Packaged lab deployments will probably install a privileged LaunchDaemon or
/// helper later. Keeping this current-user agent in core still gives the UI and
/// CLI one repeatable scheduling path for testing the same install command.
public struct LaunchAgentScheduler: Sendable {
    public static let defaultLabel = "com.maxhewett.Looper.schedule"

    public var label: String

    public init(label: String = Self.defaultLabel) {
        self.label = label
    }

    public var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    public func status() -> LaunchAgentStatus {
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return LaunchAgentStatus(isInstalled: false, plistURL: plistURL, interval: nil, arguments: [])
        }

        let interval = dictionary["StartInterval"] as? TimeInterval
        let arguments = dictionary["ProgramArguments"] as? [String] ?? []
        return LaunchAgentStatus(isInstalled: true, plistURL: plistURL, interval: interval, arguments: arguments)
    }

    public func install(
        executableURL: URL,
        manifestURL: URL? = nil,
        interval: TimeInterval,
        appContentSets: [String: [String]] = [:],
        quietHours: String? = nil,
        exclusionPreset: String? = nil
    ) throws {
        let launchAgents = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)

        var programArguments = [executableURL.path]
        if let manifestURL {
            programArguments += ["install", "--manifest", manifestURL.path]
        } else {
            programArguments.append("request-scheduled-run")
        }
        if !appContentSets.isEmpty {
            programArguments.append("--app-content-sets")
            programArguments.append(Self.encodeAppContentSets(appContentSets))
        }
        if let quietHours {
            programArguments.append("--quiet-hours")
            programArguments.append(quietHours)
        }
        if let exclusionPreset, !exclusionPreset.isEmpty {
            programArguments.append("--exclude")
            programArguments.append(exclusionPreset)
        }
        let logDirectory = LooperPaths().logDirectory
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "StartInterval": Int(interval),
            "StandardOutPath": logDirectory.appendingPathComponent("looper.out.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("looper.err.log").path
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: [.atomic])
        try? unload()
        try load()
    }

    public func uninstall() throws {
        try? unload()
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private func load() throws {
        try runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func unload() throws {
        try runLaunchctl(arguments: ["bootout", "gui/\(getuid())/\(label)"])
    }

    private func runLaunchctl(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw LooperError.scheduleFailed("launchctl \(arguments.joined(separator: " ")) exited with status \(process.terminationStatus).")
        }
    }

    private static func encodeAppContentSets(_ appContentSets: [String: [String]]) -> String {
        appContentSets
            .keys
            .sorted()
            .map { app in
                let sets = appContentSets[app] ?? []
                let setText = sets.isEmpty ? "*" : sets.joined(separator: ",")
                return "\(app)=\(setText)"
            }
            .joined(separator: ";")
    }
}
