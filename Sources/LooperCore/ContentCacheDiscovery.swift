import Foundation

struct ContentCacheServer: Identifiable, Sendable {
    let id: String
    let endpoint: String
    let healthy: Bool?
    let favored: Bool
}

struct ContentCacheDiscovery {
    let servers: [ContentCacheServer]?
    let diagnostic: String

    static func lookup() -> Self {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/AssetCacheLocatorUtil")
        process.arguments = ["-j"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                if process.isRunning { process.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Self(servers: process.terminationStatus == 0 ? parse(data) : nil,
                        diagnostic: data.isEmpty ? "Locator exit status \(process.terminationStatus)." : String(decoding: data, as: UTF8.self))
        } catch {
            return Self(servers: nil, diagnostic: error.localizedDescription)
        }
    }

    static func parse(_ data: Data) -> [ContentCacheServer]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any] else { return nil }
        var unique: [String: ContentCacheServer] = [:]
        var foundInventory = false
        for key in ["system", "current user"] {
            guard let section = results[key] as? [String: Any] else { continue }
            if section["might have"] as? Bool == false { foundInventory = true }
            guard let inventory = section["refreshed servers"] as? [String: Any],
                  let shared = inventory["shared caching"] as? [[String: Any]] else { continue }
            foundInventory = true
            for record in shared {
                guard let endpoint = record["hostport"] as? String, !endpoint.isEmpty else { continue }
                let id = (record["guid"] as? String ?? endpoint).lowercased()
                if unique[id] == nil {
                    unique[id] = ContentCacheServer(id: id, endpoint: endpoint, healthy: record["healthy"] as? Bool,
                                                   favored: record["favored"] as? Bool == true)
                }
            }
        }
        return foundInventory ? unique.values.sorted { $0.endpoint < $1.endpoint } : nil
    }
}
