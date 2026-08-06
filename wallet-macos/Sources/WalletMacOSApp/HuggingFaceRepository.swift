import Foundation

enum HuggingFaceRepositoryError: LocalizedError, Equatable {
    case malformedRepoID
    case noGGUFFiles
    case gated
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .malformedRepoID:
            return "Enter a repository as owner/name, for example unsloth/gemma-4-E2B-it-GGUF."
        case .noGGUFFiles:
            return "That repository has no GGUF files. Local Wallet can only run GGUF models."
        case .gated:
            return "That repository is gated. Accept its licence on huggingface.co, or pick another one."
        case .httpStatus(let code):
            return "Hugging Face returned HTTP \(code) for that repository."
        }
    }
}

struct HuggingFaceGGUFFile: Equatable, Identifiable {
    var id: String { path }
    let path: String
    let sizeBytes: UInt64
    let sha256: String?
    let downloadURL: URL

    /// Vision projectors and speculative-decoding sidecars ship in the same repo
    /// but cannot be loaded as the main model.
    var isAuxiliary: Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("mmproj-") || name.hasPrefix("mtp-")
    }
}

struct HuggingFaceRepositoryInfo: Equatable {
    let architecture: String?
    let trainedContextTokens: Int?
    let hasChatTemplate: Bool
    let isGated: Bool
    var files: [HuggingFaceGGUFFile] = []
}

struct HuggingFaceRepository {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func validate(repoID: String) throws -> String {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2,
              !trimmed.contains(":"),
              !trimmed.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty })
        else { throw HuggingFaceRepositoryError.malformedRepoID }
        return parts.joined(separator: "/")
    }

    func info(repoID rawRepoID: String) async throws -> HuggingFaceRepositoryInfo {
        let repoID = try Self.validate(repoID: rawRepoID)
        let modelInfo = try await get(URL(string: "https://huggingface.co/api/models/\(repoID)")!)
        var info = try Self.decodeModelInfo(modelInfo)
        guard !info.isGated else { throw HuggingFaceRepositoryError.gated }
        let tree = try await get(URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main?recursive=true")!)
        info.files = try Self.decodeTree(tree, repoID: repoID)
        return info
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HuggingFaceRepositoryError.httpStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Pure decoders

    private struct TreeEntry: Decodable {
        struct LFS: Decodable { let oid: String? }
        let type: String
        let path: String
        let size: UInt64?
        let lfs: LFS?
    }

    private struct ModelInfo: Decodable {
        struct GGUF: Decodable {
            let architecture: String?
            let context_length: Int?
            let chat_template: String?
        }
        let gated: BoolOrString?
        let gguf: GGUF?
    }

    /// `gated` is `false` or a string like "auto"/"manual".
    private enum BoolOrString: Decodable {
        case flag(Bool)
        case name(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .flag(value); return }
            self = .name((try? container.decode(String.self)) ?? "")
        }

        var isGated: Bool {
            switch self {
            case .flag(let value): return value
            case .name(let value): return !value.isEmpty
            }
        }
    }

    static func decodeModelInfo(_ data: Data) throws -> HuggingFaceRepositoryInfo {
        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        return HuggingFaceRepositoryInfo(
            architecture: info.gguf?.architecture,
            trainedContextTokens: info.gguf?.context_length,
            hasChatTemplate: (info.gguf?.chat_template?.isEmpty == false),
            isGated: info.gated?.isGated ?? false
        )
    }

    static func decodeTree(_ data: Data, repoID: String) throws -> [HuggingFaceGGUFFile] {
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        let files = entries
            .filter { $0.type == "file" && $0.path.hasSuffix(".gguf") }
            .map { entry in
                HuggingFaceGGUFFile(
                    path: entry.path,
                    sizeBytes: entry.size ?? 0,
                    sha256: entry.lfs?.oid,
                    downloadURL: URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(entry.path)")!
                )
            }
            .sorted { $0.sizeBytes < $1.sizeBytes }
        guard !files.isEmpty else { throw HuggingFaceRepositoryError.noGGUFFiles }
        return files
    }
}
