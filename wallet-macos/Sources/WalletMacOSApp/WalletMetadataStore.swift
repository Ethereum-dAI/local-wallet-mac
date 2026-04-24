import Foundation

// WalletMetadataStore persists non-secret demo wallet state. The Secure Enclave
// key itself is not stored here; only metadata needed to reconnect the app to
// the same wallet identity across launches.
struct WalletMetadataStore {
    let fileURL: URL

    init(fileURL: URL = WalletMetadataStore.defaultURL()) {
        self.fileURL = fileURL
    }

    func load() throws -> WalletRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WalletRecord.self, from: data)
        } catch is DecodingError {
            throw AppError.corruptedMetadataStore
        }
    }

    func save(_ record: WalletRecord) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(record)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: fileURL)
    }

    private static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("LocalWallet", isDirectory: true)
            .appendingPathComponent("wallet-record.json", isDirectory: false)
    }
}
