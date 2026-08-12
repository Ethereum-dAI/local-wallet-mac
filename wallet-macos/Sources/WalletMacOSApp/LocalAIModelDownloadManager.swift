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

struct ModelDownloadProgress: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double?

    init(completedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double?) {
        self.totalBytes = max(0, totalBytes)
        self.completedBytes = min(max(0, completedBytes), max(0, totalBytes))
        if let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond > 0 {
            self.bytesPerSecond = bytesPerSecond
        } else {
            self.bytesPerSecond = nil
        }
    }

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    var estimatedSecondsRemaining: TimeInterval? {
        guard let bytesPerSecond else { return nil }
        return Double(totalBytes - completedBytes) / bytesPerSecond
    }

    var statusText: String {
        var parts = [Self.progressText(completedBytes: completedBytes, totalBytes: totalBytes)]
        if let bytesPerSecond {
            parts.append("\(Self.rateText(bytesPerSecond))/s")
        }
        if let seconds = estimatedSecondsRemaining, seconds > 0 {
            parts.append(Self.etaText(seconds))
        }
        return parts.joined(separator: " — ")
    }

    func isVisibleChange(from current: ModelDownloadProgress) -> Bool {
        Int(fractionCompleted * 100) != Int(current.fractionCompleted * 100)
            || statusText != current.statusText
    }

    private static func progressText(completedBytes: Int64, totalBytes: Int64) -> String {
        let completed = byteValue(Double(completedBytes), includeDecimalBelowTen: false)
        let total = byteValue(Double(totalBytes), includeDecimalBelowTen: false)
        if completed.unit == total.unit {
            return "\(completed.number) of \(total.number) \(total.unit)"
        }
        return "\(completed.number) \(completed.unit) of \(total.number) \(total.unit)"
    }

    private static func rateText(_ bytesPerSecond: Double) -> String {
        decimalText(bytesPerSecond, includeDecimalBelowTen: true)
    }

    private static func decimalText(_ bytes: Double, includeDecimalBelowTen: Bool) -> String {
        let value = byteValue(bytes, includeDecimalBelowTen: includeDecimalBelowTen)
        return "\(value.number) \(value.unit)"
    }

    private static func byteValue(
        _ bytes: Double,
        includeDecimalBelowTen: Bool
    ) -> (number: String, unit: String) {
        let units = [(1_000_000_000.0, "GB"), (1_000_000.0, "MB"), (1_000.0, "KB")]
        guard let (scale, unit) = units.first(where: { bytes >= $0.0 }) else {
            return ("\(Int(bytes.rounded()))", "B")
        }
        let value = bytes / scale
        let decimals: Int
        if includeDecimalBelowTen {
            decimals = value < 100 ? 1 : 0
        } else if abs(value - value.rounded()) < 0.005 {
            decimals = 0
        } else {
            decimals = value < 10 ? 2 : 0
        }
        return (String(format: "%.*f", decimals, value), unit)
    }

    private static func etaText(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "less than 1 min left"
        }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 {
            return "about \(minutes) min left"
        }
        let hours = max(1, Int((Double(minutes) / 60).rounded()))
        return "about \(hours) hr left"
    }
}

/// Builds stable transfer telemetry from URLSession's noisy per-chunk callbacks.
/// Each download owns one estimator, so samples from separate downloads can never
/// contaminate one another.
final class ModelDownloadProgressEstimator: @unchecked Sendable {
    private let lock = NSLock()
    private let smoothingFactor: Double
    private let minimumSampleInterval: TimeInterval
    private var lastDate: Date
    private var lastBytes: Int64 = 0
    private var smoothedBytesPerSecond: Double?
    private var hasBaseline = false

    init(
        startedAt: Date = Date(),
        smoothingFactor: Double = 0.2,
        minimumSampleInterval: TimeInterval = 0.75
    ) {
        self.lastDate = startedAt
        self.smoothingFactor = min(1, max(0, smoothingFactor))
        self.minimumSampleInterval = max(0, minimumSampleInterval)
    }

    func record(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
        at date: Date = Date()
    ) -> ModelDownloadProgress {
        lock.lock()
        defer { lock.unlock() }

        guard hasBaseline else {
            hasBaseline = true
            lastDate = date
            lastBytes = max(0, totalBytesWritten)
            return ModelDownloadProgress(
                completedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
                bytesPerSecond: nil
            )
        }

        let elapsed = date.timeIntervalSince(lastDate)
        let byteDelta = totalBytesWritten - lastBytes
        if elapsed >= minimumSampleInterval, byteDelta >= 0 {
            let instantaneous = Double(byteDelta) / elapsed
            if instantaneous.isFinite, instantaneous > 0 {
                if let existing = smoothedBytesPerSecond {
                    smoothedBytesPerSecond = smoothingFactor * instantaneous
                        + (1 - smoothingFactor) * existing
                } else {
                    smoothedBytesPerSecond = instantaneous
                }
            }
            lastDate = date
            lastBytes = max(lastBytes, totalBytesWritten)
        }

        return ModelDownloadProgress(
            completedBytes: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite,
            bytesPerSecond: smoothedBytesPerSecond
        )
    }
}

typealias LocalAIModelDownloadProgressHandler = @MainActor @Sendable (ModelDownloadProgress) -> Void

protocol LocalAIModelManaging: Sendable {
    func existingFileURL(for model: LocalAIModel) -> URL?
    func verifyExistingFile(_ model: LocalAIModel, at fileURL: URL) async throws -> URL
    func download(
        _ model: LocalAIModel,
        progress: @escaping LocalAIModelDownloadProgressHandler
    ) async throws -> URL
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

final class LocalAIModelDownloadManager: NSObject, URLSessionDownloadDelegate, LocalAIModelManaging, @unchecked Sendable {
    typealias ProgressHandler = LocalAIModelDownloadProgressHandler

    private struct ActiveDownload {
        let expectedSHA256: String?
        /// Checked only when there is no digest — see the verification block in
        /// `didFinishDownloadingTo`.
        let expectedSizeBytes: UInt64?
        let destinationURL: URL
        let progressEstimator: ModelDownloadProgressEstimator
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

    func existingFileURL(for model: LocalAIModel) -> URL? {
        if let localURL = try? localFileURL(for: model),
           FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        if let bundledURL = bundledFileURL(for: model),
           FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }
        return nil
    }

    func verifyExistingFile(_ model: LocalAIModel, at fileURL: URL) async throws -> URL {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LocalAIModelDownloadError.missingDownload
        }

        let actualChecksum = try await Task.detached(priority: .utility) {
            try Self.sha256Hex(of: fileURL)
        }.value
        guard actualChecksum == model.sha256.lowercased() else {
            throw LocalAIModelDownloadError.checksumMismatch(
                expected: model.sha256,
                actual: actualChecksum
            )
        }
        return fileURL
    }

    func download(
        _ model: LocalAIModel,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        let destinationURL = try localFileURL(for: model)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            do {
                return try await verifyExistingFile(model, at: destinationURL)
            } catch LocalAIModelDownloadError.checksumMismatch {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }
        if let bundledURL = bundledFileURL(for: model),
           FileManager.default.fileExists(atPath: bundledURL.path) {
            return try await verifyExistingFile(model, at: bundledURL)
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
                progressEstimator: ModelDownloadProgressEstimator(),
                progressHandler: progress,
                continuation: continuation
            )
            guard slot.claim(activeDownload) else {
                continuation.resume(throwing: LocalAIModelDownloadError.downloadAlreadyInProgress)
                return
            }
            let task = session.downloadTask(with: model.artifactURL)
            task.priority = URLSessionTask.highPriority
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
                progressEstimator: ModelDownloadProgressEstimator(),
                progressHandler: progress,
                continuation: continuation
            )
            guard slot.claim(activeDownload) else {
                continuation.resume(throwing: LocalAIModelDownloadError.downloadAlreadyInProgress)
                return
            }
            let task = session.downloadTask(with: request.url)
            task.priority = URLSessionTask.highPriority
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

        let progress = activeDownload.progressEstimator.record(
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
        Task { @MainActor in
            activeDownload.progressHandler(progress)
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

            let completedBytes = Int64(try Self.fileSize(of: activeDownload.destinationURL))
            let completedProgress = activeDownload.progressEstimator.record(
                totalBytesWritten: completedBytes,
                totalBytesExpectedToWrite: completedBytes
            )
            Task { @MainActor in activeDownload.progressHandler(completedProgress) }
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
