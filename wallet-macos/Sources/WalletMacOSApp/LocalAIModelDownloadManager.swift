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

    init(model: LocalAIModel) {
        modelID = model.id
        displayName = model.name
        repoID = model.artifactRepo
        fileName = model.artifactFileName
        destinationFileName = model.artifactFileName
        url = model.artifactURL
        expectedSHA256 = model.sha256
        sizeBytes = model.memoryProfile.weightBytes
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
    }
}

enum LocalAIModelDownloadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case checksumMismatch(expected: String, actual: String)
    case missingDownload
    case insufficientDisk(neededBytes: UInt64, availableBytes: UInt64)
    case downloadAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Hugging Face returned an invalid model download response."
        case .httpStatus(let status):
            return "Hugging Face model download failed with HTTP \(status)."
        case .checksumMismatch:
            return "The downloaded model did not pass verification. Try downloading it again."
        case .missingDownload:
            return "The downloaded model file could not be found."
        case .insufficientDisk(let needed, let available):
            let neededText = ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)
            let availableText = ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)
            return "This model needs \(neededText) but only \(availableText) is free."
        case .downloadAlreadyInProgress:
            return "Another model is already downloading. Wait for it to finish, or cancel it first."
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
        let destinationURL: URL
        let progressHandler: ProgressHandler
        let continuation: CheckedContinuation<URL, Error>
    }

    private let slot = DownloadSlot<ActiveDownload>()
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
                destinationURL: destinationURL,
                progressHandler: progress,
                continuation: continuation
            )
            guard slot.claim(activeDownload) else {
                continuation.resume(throwing: LocalAIModelDownloadError.downloadAlreadyInProgress)
                return
            }
            session.downloadTask(with: model.artifactURL).resume()
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
                destinationURL: destinationURL,
                progressHandler: progress,
                continuation: continuation
            )
            guard slot.claim(activeDownload) else {
                continuation.resume(throwing: LocalAIModelDownloadError.downloadAlreadyInProgress)
                return
            }
            session.downloadTask(with: request.url).resume()
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

            if let expected = activeDownload.expectedSHA256?.lowercased() {
                let actualChecksum = try Self.sha256Hex(of: activeDownload.destinationURL)
                guard actualChecksum == expected else {
                    try? FileManager.default.removeItem(at: activeDownload.destinationURL)
                    throw LocalAIModelDownloadError.checksumMismatch(
                        expected: expected,
                        actual: actualChecksum
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
            return
        }
        activeDownload.continuation.resume(throwing: error)
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
