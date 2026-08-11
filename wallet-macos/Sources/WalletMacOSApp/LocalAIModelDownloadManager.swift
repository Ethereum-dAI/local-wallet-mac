import CryptoKit
import Foundation

/// A single downloadable GGUF, whether it came from the curated catalog or from a
/// repository the user typed in.
struct ModelDownloadRequest: Equatable {
    let modelID: String
    let displayName: String
    let repoID: String
    let fileName: String
    /// Destination file name, namespaced so two repos publishing `model.gguf`
    /// cannot overwrite each other. Curated models keep their historical name so
    /// existing installs are found without a re-download.
    let destinationFileName: String
    let url: URL
    let expectedSHA256: String?
    let sizeBytes: UInt64
    /// The exact on-disk byte count the source promised, when it promised one.
    ///
    /// Only meaningful as an integrity check: it is the fallback for a file with
    /// no digest, where otherwise nothing at all is verified. Distinct from
    /// `sizeBytes`, which curated models fill from the memory profile's weight
    /// estimate for display and which is not a byte-exact figure.
    let expectedSizeBytes: UInt64?

    init(model: LocalAIModel) {
        modelID = model.id
        displayName = model.name
        repoID = model.artifactRepo
        fileName = model.artifactFileName
        destinationFileName = model.artifactFileName
        url = model.artifactURL
        expectedSHA256 = model.sha256
        sizeBytes = model.memoryProfile.weightBytes
        // Curated models are pinned by digest, which subsumes a size check.
        expectedSizeBytes = nil
    }

    init(repoID: String, file: HuggingFaceGGUFFile) {
        let leaf = (file.path as NSString).lastPathComponent
        modelID = "\(repoID)#\(file.path)"
        displayName = (leaf as NSString).deletingPathExtension
        self.repoID = repoID
        fileName = file.path
        let slug = repoID.replacingOccurrences(of: "/", with: "_")
        destinationFileName = "\(slug)__\(leaf)"
        url = file.downloadURL
        expectedSHA256 = file.sha256
        sizeBytes = file.sizeBytes
        // The tree API's byte count, which is exact. Zero means the field was
        // absent, not that the file is empty.
        expectedSizeBytes = file.sizeBytes > 0 ? file.sizeBytes : nil
    }
}

enum LocalAIModelDownloadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case checksumMismatch(expected: String, actual: String)
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case missingDownload
    case insufficientDisk(neededBytes: UInt64, availableBytes: UInt64)
    case downloadAlreadyInProgress
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Hugging Face returned an invalid model download response."
        case .httpStatus(let status):
            return "Hugging Face model download failed with HTTP \(status)."
        case .checksumMismatch:
            return "The downloaded model did not pass verification. Try downloading it again."
        case .sizeMismatch(let expected, let actual):
            let expectedText = ByteCountFormatter.string(fromByteCount: Int64(expected), countStyle: .file)
            let actualText = ByteCountFormatter.string(fromByteCount: Int64(actual), countStyle: .file)
            return "The download is incomplete — \(actualText) of \(expectedText) arrived. Try downloading it again."
        case .missingDownload:
            return "The downloaded model file could not be found."
        case .insufficientDisk(let needed, let available):
            let neededText = ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)
            let availableText = ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)
            return "This model needs \(neededText) but only \(availableText) is free."
        case .downloadAlreadyInProgress:
            return "Another model is already downloading. Cancel it, or wait for it to finish."
        case .cancelled:
            return "Download cancelled. The partial file was discarded."
        }
    }
}

/// Bookkeeping for the one in-flight download a `LocalAIModelDownloadManager`
/// allows at a time. `claim`, `current`, and `release` each execute under a single
/// lock acquisition, so an overlapping caller can be refused atomically instead of
/// silently overwriting the in-flight download's bookkeeping — which would
/// otherwise cross-wire one download's bytes/checksum onto another's destination,
/// or abandon a continuation that never resumes.
final class DownloadSlot<Occupant>: @unchecked Sendable {
    private let lock = NSLock()
    private var occupant: Occupant?

    /// Claims the slot if it is empty. Returns `false`, leaving the existing
    /// occupant untouched, if a download is already in flight.
    func claim(_ download: Occupant) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard occupant == nil else { return false }
        occupant = download
        return true
    }

    func current() -> Occupant? {
        lock.lock()
        defer { lock.unlock() }
        return occupant
    }

    /// Empties the slot and returns whatever occupied it, or `nil` if it was
    /// already empty.
    func release() -> Occupant? {
        lock.lock()
        defer { lock.unlock() }
        let download = occupant
        occupant = nil
        return download
    }
}

final class LocalAIModelDownloadManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @MainActor (Double) -> Void

    private struct ActiveDownload {
        let expectedSHA256: String?
        /// Checked only when there is no digest — see the verification block in
        /// `didFinishDownloadingTo`.
        let expectedSizeBytes: UInt64?
        let destinationURL: URL
        let progressHandler: ProgressHandler
        let continuation: CheckedContinuation<URL, Error>
    }

    private let slot = DownloadSlot<ActiveDownload>()
    /// The in-flight `URLSessionDownloadTask`, so `cancelActiveDownload` can stop
    /// it. Kept beside the slot rather than inside `ActiveDownload` because the
    /// task does not exist until after the slot has been claimed — claiming first
    /// is what makes the refusal of a second download atomic.
    private let taskLock = NSLock()
    private var activeTask: URLSessionDownloadTask?

    private func setActiveTask(_ task: URLSessionDownloadTask?) {
        taskLock.lock()
        activeTask = task
        taskLock.unlock()
    }

    /// Stops the download in flight, if any. The URLSession delegate then reports
    /// `NSURLErrorCancelled`, which `didCompleteWithError` maps to
    /// `.cancelled` so the caller gets an intentional outcome rather than a
    /// network failure. Partial bytes are dropped by URLSession — cancelling
    /// without `resumeData` leaves nothing on disk to clean up.
    ///
    /// Returns false when there was nothing to cancel, so a stale button press
    /// cannot report a cancellation that did not happen.
    @discardableResult
    func cancelActiveDownload() -> Bool {
        taskLock.lock()
        let task = activeTask
        activeTask = nil
        taskLock.unlock()
        guard let task else { return false }
        task.cancel()
        return true
    }
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 3
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func localFileURL(for model: LocalAIModel) throws -> URL {
        try Self.modelsDirectory()
            .appendingPathComponent(model.artifactFileName, isDirectory: false)
    }

    func localFileURL(for request: ModelDownloadRequest) throws -> URL {
        try Self.modelsDirectory()
            .appendingPathComponent(request.destinationFileName, isDirectory: false)
    }

    /// Leaves 2 GB of slack so a download cannot fill the volume.
    static func assertDiskSpace(neededBytes: UInt64, budget: HardwareBudget) throws {
        let slack: UInt64 = 2 * 1_073_741_824
        guard budget.freeDiskBytes > neededBytes + slack else {
            throw LocalAIModelDownloadError.insufficientDisk(
                neededBytes: neededBytes,
                availableBytes: budget.freeDiskBytes
            )
        }
    }

    func bundledFileURL(for model: LocalAIModel) -> URL? {
        Self.bundledFileURL(for: model)
    }

    static func bundledFileURL(for model: LocalAIModel, bundle: Bundle = .main) -> URL? {
        let fileURL = URL(fileURLWithPath: model.artifactFileName)
        let fileExtension = fileURL.pathExtension
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        return bundle.url(forResource: baseName, withExtension: fileExtension, subdirectory: "Models")
    }

    func isInstalled(_ model: LocalAIModel) -> Bool {
        if let bundledURL = bundledFileURL(for: model),
           FileManager.default.fileExists(atPath: bundledURL.path) {
            return true
        }
        guard let url = try? localFileURL(for: model) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func download(
        _ model: LocalAIModel,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        let destinationURL = try localFileURL(for: model)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        if let bundledURL = bundledFileURL(for: model),
           FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        return try await withCheckedThrowingContinuation { continuation in
            let activeDownload = ActiveDownload(
                expectedSHA256: model.sha256,
                expectedSizeBytes: nil,
                destinationURL: destinationURL,
                progressHandler: progress,
                continuation: continuation
            )
            guard slot.claim(activeDownload) else {
                continuation.resume(throwing: LocalAIModelDownloadError.downloadAlreadyInProgress)
                return
            }
            let task = session.downloadTask(with: model.artifactURL)
            setActiveTask(task)
            task.resume()
        }
    }

    func download(
        _ request: ModelDownloadRequest,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        let destinationURL = try localFileURL(for: request)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try await withCheckedThrowingContinuation { continuation in
            let activeDownload = ActiveDownload(
                expectedSHA256: request.expectedSHA256,
                expectedSizeBytes: request.expectedSizeBytes,
                destinationURL: destinationURL,
                progressHandler: progress,
                continuation: continuation
            )
            guard slot.claim(activeDownload) else {
                continuation.resume(throwing: LocalAIModelDownloadError.downloadAlreadyInProgress)
                return
            }
            let task = session.downloadTask(with: request.url)
            setActiveTask(task)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let activeDownload = currentDownload() else {
            return
        }

        let fraction = min(0.99, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        Task { @MainActor in
            activeDownload.progressHandler(fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        setActiveTask(nil)
        guard let activeDownload = takeDownload() else {
            return
        }

        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw LocalAIModelDownloadError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw LocalAIModelDownloadError.httpStatus(response.statusCode)
            }
            guard FileManager.default.fileExists(atPath: location.path) else {
                throw LocalAIModelDownloadError.missingDownload
            }

            if FileManager.default.fileExists(atPath: activeDownload.destinationURL.path) {
                try FileManager.default.removeItem(at: activeDownload.destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: activeDownload.destinationURL)

            // A digest is the real check. Without one — Hugging Face's tree API
            // omits the LFS oid for some entries — fall back to the byte count
            // rather than accepting the transfer unverified: `URLSession`'s
            // completion says nothing about content, so a proxy or CDN that
            // truncated the body would otherwise be reported as a successful
            // install and only fail later, inside llama.cpp's GGUF parse, with
            // nothing pointing at the download.
            if let expected = activeDownload.expectedSHA256?.lowercased() {
                let actualChecksum = try Self.sha256Hex(of: activeDownload.destinationURL)
                guard actualChecksum == expected else {
                    try? FileManager.default.removeItem(at: activeDownload.destinationURL)
                    throw LocalAIModelDownloadError.checksumMismatch(
                        expected: expected,
                        actual: actualChecksum
                    )
                }
            } else if let expectedSize = activeDownload.expectedSizeBytes {
                let actualSize = try Self.fileSize(of: activeDownload.destinationURL)
                guard actualSize == expectedSize else {
                    try? FileManager.default.removeItem(at: activeDownload.destinationURL)
                    throw LocalAIModelDownloadError.sizeMismatch(
                        expected: expectedSize,
                        actual: actualSize
                    )
                }
            }

            Task { @MainActor in
                activeDownload.progressHandler(1)
            }
            activeDownload.continuation.resume(returning: activeDownload.destinationURL)
        } catch {
            activeDownload.continuation.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let activeDownload = takeDownload() else {
            setActiveTask(nil)
            return
        }
        setActiveTask(nil)
        // A cancelled transfer is a user decision, not a failure to report as one.
        let isCancelled = (error as NSError).domain == NSURLErrorDomain
            && (error as NSError).code == NSURLErrorCancelled
        activeDownload.continuation.resume(
            throwing: isCancelled ? LocalAIModelDownloadError.cancelled : error
        )
    }

    private func currentDownload() -> ActiveDownload? {
        slot.current()
    }

    private func takeDownload() -> ActiveDownload? {
        slot.release()
    }

    private static func modelsDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport
            .appendingPathComponent("LocalWallet", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The fallback integrity check for a file the source gave no digest for.
    static func fileSize(of url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values.fileSize ?? 0)
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
