import Foundation

/// Progress snapshot emitted after a network transfer finishes or resumes.
public struct DownloadProgress: Sendable {
    public var package: LoopPackage
    public var receivedBytes: Int64
    public var expectedBytes: Int64?
}

/// Downloader that can continue from a previously interrupted `.part` file.
///
/// Apple CDN endpoints normally support byte ranges, but the code treats that
/// as an optimization rather than an assumption. If the server ignores the Range
/// request and returns a full `200 OK`, the partial file is replaced instead of
/// appended.
public actor ResumableDownloader {
    public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void

    private lazy var cacheInventory = ContentCacheDiscovery.lookup().servers
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func download(
        package: LoopPackage,
        to destination: URL,
        partialFile: URL,
        progress: ProgressHandler? = nil
    ) async throws -> (source: DownloadSource, bytes: Int64) {
        // A completed cached package is reusable only after it still passes the
        // manifest hash check. This protects against interrupted copies or
        // manual cache edits.
        if fileManager.fileExists(atPath: destination.path) {
            try validate(package: package, file: destination)
            return (.local, 0)
        }

        var request = URLRequest(url: package.url)
        let existingBytes = existingPartialSize(at: partialFile)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let bridge = DownloadTaskBridge(
            package: package,
            existingBytes: existingBytes,
            progress: progress
        )
        let session = URLSession(configuration: .default, delegate: bridge, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (downloadedFile, response, metrics) = try await bridge.download(request: request, session: session)
        let httpResponse = response as? HTTPURLResponse
        if let status = httpResponse?.statusCode, !(200..<300).contains(status) {
            let errorBytes = existingPartialSize(at: downloadedFile)
            try? fileManager.removeItem(at: downloadedFile)
            let endpoint = Self.logEndpoint(package.url)
            let finalEndpoint = response.url.map(Self.logEndpoint) ?? endpoint
            let redirected = endpoint == finalEndpoint ? "" : " (redirected to " + finalEndpoint + ")"
            let range = request.value(forHTTPHeaderField: "Range") ?? "none"
            throw LooperError.downloadFailed(
                "GET \(endpoint)\(redirected) returned HTTP \(status). Range: \(range). Error response: \(errorBytes) bytes."
            )
        }
        let canAppend = existingBytes > 0 && httpResponse?.statusCode == 206

        // Range resume is only valid when the server explicitly returns
        // `206 Partial Content`. A plain `200` means it sent a whole file.
        let expected = expectedLength(from: response, existingBytes: canAppend ? existingBytes : 0)
        let downloadedBytes = existingPartialSize(at: downloadedFile)
        if !canAppend, fileManager.fileExists(atPath: partialFile.path) {
            try fileManager.removeItem(at: partialFile)
        }
        if canAppend {
            try append(downloadedFile, to: partialFile)
            try? fileManager.removeItem(at: downloadedFile)
        } else {
            try replace(partialFile, with: downloadedFile)
        }

        let received = (canAppend ? existingBytes : 0) + downloadedBytes
        progress?(DownloadProgress(package: package, receivedBytes: received, expectedBytes: expected))

        // `expectedContentLength` is not guaranteed for every CDN response. When
        // it is available, keep an incomplete transfer as `.part` for the next
        // run rather than promoting it to an installable package.
        if let expected, received < expected {
            throw LooperError.incompleteDownload(received: received, expected: expected)
        }

        try validate(package: package, file: partialFile)
        try replace(destination, with: partialFile)
        let source = source(for: metrics)
        return (source, source == .local ? 0 : downloadedBytes)
    }

    private static func logEndpoint(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return "download endpoint" }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? "download endpoint"
    }

    private func source(for metrics: URLSessionTaskTransactionMetrics?) -> DownloadSource {
        guard let metrics else { return .unknown }
        if metrics.resourceFetchType == .localCache { return .local }
        guard metrics.resourceFetchType == .networkLoad, let address = metrics.remoteAddress,
              let port = metrics.remotePort, let cacheInventory else { return .unknown }
        let endpoint = address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
        if cacheInventory.contains(where: { $0.endpoint.caseInsensitiveCompare(endpoint) == .orderedSame }) {
            return .contentCache
        }
        guard !metrics.isProxyConnection, metrics.request.url?.scheme == "https",
              let host = metrics.request.url?.host?.lowercased(),
              host.hasSuffix(".apple.com") || host.hasSuffix(".cdn-apple.com") else { return .unknown }
        return .web
    }

    private func validate(package: LoopPackage, file: URL) throws {
        // Hashes are optional so early discovery manifests can still be useful.
        // Production manifests should include them whenever Apple publishes
        // stable package URLs.
        guard let expectedHash = package.sha256?.lowercased(), !expectedHash.isEmpty else { return }
        let actualHash = try Hashing.sha256Hex(of: file)
        guard actualHash == expectedHash else {
            throw LooperError.hashMismatch(package: package.displayName, expected: expectedHash, actual: actualHash)
        }
    }

    private func existingPartialSize(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private func expectedLength(from response: URLResponse, existingBytes: Int64) -> Int64? {
        guard response.expectedContentLength > 0 else { return nil }
        return response.expectedContentLength + existingBytes
    }

    private func append(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        if !fileManager.fileExists(atPath: destination.path) {
            _ = fileManager.createFile(atPath: destination.path, contents: nil)
        }

        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.seekToEnd()
        try output.write(contentsOf: input.readDataToEndOfFile())
    }

    private func replace(_ destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }
}

private final class DownloadTaskBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let package: LoopPackage
    private let existingBytes: Int64
    private let progress: ResumableDownloader.ProgressHandler?
    private var continuation: CheckedContinuation<(URL, URLResponse, URLSessionTaskTransactionMetrics?), Error>?
    private var metrics: URLSessionTaskTransactionMetrics?
    private var downloadedFile: URL?
    private var response: URLResponse?

    init(
        package: LoopPackage,
        existingBytes: Int64,
        progress: ResumableDownloader.ProgressHandler?
    ) {
        self.package = package
        self.existingBytes = existingBytes
        self.progress = progress
    }

    func download(request: URLRequest, session: URLSession) async throws -> (URL, URLResponse, URLSessionTaskTransactionMetrics?) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let response = downloadTask.response else { return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
        let canAppend = existingBytes > 0 && (response as? HTTPURLResponse)?.statusCode == 206
        let baseBytes = canAppend ? existingBytes : 0
        let expected = totalBytesExpectedToWrite > 0 ? baseBytes + totalBytesExpectedToWrite : nil
        progress?(DownloadProgress(
            package: package,
            receivedBytes: baseBytes + totalBytesWritten,
            expectedBytes: expected
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let temporaryURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("Looper-\(UUID().uuidString)")
            .appendingPathExtension("pkg.download")
        do {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try FileManager.default.removeItem(at: temporaryURL)
            }
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            downloadedFile = temporaryURL
            response = downloadTask.response
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics.transactionMetrics.last
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }

        guard let downloadedFile,
              let response = response ?? task.response else {
            continuation?.resume(throwing: LooperError.downloadFailed("Download finished without a temporary file."))
            continuation = nil
            return
        }

        continuation?.resume(returning: (downloadedFile, response, metrics))
        continuation = nil
    }
}
