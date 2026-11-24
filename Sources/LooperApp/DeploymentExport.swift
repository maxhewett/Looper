import Foundation

enum DeploymentExport: String, CaseIterable {
    case profile = "Configuration profile"
    case preferences = "Preferences plist"
    case schema = "Jamf schema"

    var filename: String {
        switch self {
        case .profile: return "Looper-Lab.mobileconfig"
        case .preferences: return "com.maxhewett.Looper.plist"
        case .schema: return "Jamf-Looper.schema.json"
        }
    }

    func data(settings: LooperSettings, skipSetup: Bool, preload: Bool,
              scheduled: Bool, quietHours: String?, resources: URL) throws -> Data {
        if self == .schema {
            return try Data(contentsOf: resources.appendingPathComponent(filename))
        }
        let scope = settings.runAppContentSets.mapValues { sets -> Any in
            if sets.isEmpty { return "All" }
            if sets.count == 1 { return sets[0] }
            return sets
        }
        var values: [String: Any] = [
            "RunAppContentSets": scope,
            "AppPackageOverrides": (settings.appPackageOverrides ?? [:]).mapValues { ["Only": $0.only, "Skip": $0.skip] },
            "ExcludedPackageIDs": settings.excludedPackageIDs.joined(separator: ", "),
            "PackagePriorities": settings.packagePriorities,
            "LogRetentionDays": settings.logRetentionDays,
            "HelperRunMode": settings.helperRunMode.rawValue,
            "NotifyRunFailures": settings.notifyRunFailures,
            "NotifyRunSummaries": settings.notifyRunSummaries,
            "NotifyNewLoopsAvailable": settings.notifyNewLoopsAvailable,
            "NotifyRelaunchPrompts": settings.notifyRelaunchPrompts,
            "RunAtLogin": LooperApp.runAtLogin,
            "SkipSetupAssistant": skipSetup,
            "ManagedPreloadEnabled": preload,
            "ScheduledInstallEnabled": scheduled
        ]
        if let quietHours, !quietHours.isEmpty { values["ScheduleQuietHours"] = quietHours }
        var document = values
        if self == .profile {
            let template = try Data(contentsOf: resources.appendingPathComponent("Looper-Lab.mobileconfig"))
            guard var profile = try PropertyListSerialization.propertyList(from: template, format: nil) as? [String: Any],
                  var payloads = profile["PayloadContent"] as? [[String: Any]],
                  let index = payloads.firstIndex(where: { $0["PayloadType"] as? String == "com.apple.ManagedClient.preferences" })
            else { throw CocoaError(.fileReadCorruptFile) }
            let id = UUID().uuidString
            let identifier = "com.maxhewett.Looper.lab." + id
            profile["PayloadIdentifier"] = identifier
            profile["PayloadUUID"] = id
            for i in payloads.indices {
                let uuid = UUID().uuidString
                payloads[i]["PayloadIdentifier"] = identifier + "." + uuid
                payloads[i]["PayloadUUID"] = uuid
            }
            payloads[index]["PayloadContent"] = ["com.maxhewett.Looper": ["Forced": [["mcx_preference_settings": values]]]]
            profile["PayloadContent"] = payloads
            document = profile
        }
        return try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
    }
}
