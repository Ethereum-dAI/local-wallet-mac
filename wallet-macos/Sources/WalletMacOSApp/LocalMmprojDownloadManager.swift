import CryptoKit
import Foundation

enum LocalMmprojDownloadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case checksumMismatch(expected: String, actual: String)
    case missingDownload

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Hugging Face returned an invalid mmproj download response."
        case .httpStatus(let status):
            return "Hugging Face mmproj download failed with HTTP \(status)."
        case .checksumMismatch:
            return "The downloaded mmproj did not pass verification. Try downloading it again."
        case .missingDownload:
            return "The downloaded mmproj file could not be found."
        }
    }
}

final class LocalMmprojDownloadManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @MainActor (Double) -> Void

    private struct ActiveDownload {
        let model: LocalMmproj
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

    func localFileURL(for model: LocalMmproj) throws -> URL {
        try Self.modelsDirectory()
            .appendingPathComponent(model.artifactFileName, isDirectory: false)
    }

    func isInstalled(_ model: LocalMmproj) -> Bool {
        guard let url = try? localFileURL(for: model) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func download(
        _ model: LocalMmproj,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        let destinationURL = try localFileURL(for: model)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
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
                throw LocalMmprojDownloadError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw LocalMmprojDownloadError.httpStatus(response.statusCode)
            }
            guard FileManager.default.fileExists(atPath: location.path) else {
                throw LocalMmprojDownloadError.missingDownload
            }

            if FileManager.default.fileExists(atPath: activeDownload.destinationURL.path) {
                try FileManager.default.removeItem(at: activeDownload.destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: activeDownload.destinationURL)

            let actualChecksum = try Self.sha256Hex(of: activeDownload.destinationURL)
            guard actualChecksum == activeDownload.model.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: activeDownload.destinationURL)
                throw LocalMmprojDownloadError.checksumMismatch(
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
