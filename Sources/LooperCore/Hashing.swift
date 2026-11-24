import CryptoKit
import Foundation

public enum Hashing {
    /// Stream large package files through CryptoKit rather than loading them
    /// fully into memory. Apple loop packages can be large enough for this to
    /// matter on shared lab machines.
    public static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1024 * 1024)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
