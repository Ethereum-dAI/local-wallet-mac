import CryptoKit
import Foundation

enum LocalAIModelDownloadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case checksumMismatch(expected: String, actual: String)
    case missingDownload

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
        }
    }
}

final class LocalAIModelDownloadManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @MainActor (Double) -> Void

    private struct ActiveDownload {
        let model: LocalAIModel
        let destinationURL: URL
        let progressHandler: ProgressHandler
        let continuation: CheckedContinuation<URL, Error>
    }

    private let lock = NSLock()
    private var activeDownload: ActiveDownload?
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
                model: model,
                destinationURL: destinationURL,
                progressHandler: progress,
                continuation: continuation
            )
            store(activeDownload)
            session.downloadTask(with: model.artifactURL).resume()
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

            let actualChecksum = try Self.sha256Hex(of: activeDownload.destinationURL)
            guard actualChecksum == activeDownload.model.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: activeDownload.destinationURL)
                throw LocalAIModelDownloadError.checksumMismatch(
                    expected: activeDownload.model.sha256,
                    actual: actualChecksum
                )
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

    private func store(_ download: ActiveDownload) {
        lock.lock()
        activeDownload = download
        lock.unlock()
    }

    private func currentDownload() -> ActiveDownload? {
        lock.lock()
        defer { lock.unlock() }
        return activeDownload
    }

    private func takeDownload() -> ActiveDownload? {
        lock.lock()
        defer { lock.unlock() }
        let download = activeDownload
        activeDownload = nil
        return download
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
