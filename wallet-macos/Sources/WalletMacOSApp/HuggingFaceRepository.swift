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

    /// Hugging Face owner and repo names are restricted to ASCII letters, digits,
    /// hyphen, underscore and period. Enforcing that as an allowlist — rather than
    /// blocklisting individual characters like `#`, `?`, `:` — rejects URL
    /// metacharacters, whitespace, Unicode and path-traversal segments in one rule.
    private static let allowedSegmentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_."
    )

    private static func isValidSegment(_ segment: Substring) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != ".." else { return false }
        return segment.unicodeScalars.allSatisfy { allowedSegmentCharacters.contains($0) }
    }

    static func validate(repoID: String) throws -> String {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(isValidSegment)
        else { throw HuggingFaceRepositoryError.malformedRepoID }
        return parts.joined(separator: "/")
    }

    /// Builds a `https://huggingface.co` API URL via `URLComponents` rather than raw
    /// string interpolation, so a `repoID` segment or query value can never spill
    /// into the wrong URL component (e.g. a stray `#`/`?` truncating the request).
    private static func apiURL(pathSuffix: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = pathSuffix
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw HuggingFaceRepositoryError.malformedRepoID }
        return url
    }

    /// The file `path` here comes from the (untrusted) tree API response, not from
    /// `validate(repoID:)`, so it is percent-encoded via `URLComponents` rather than
    /// trusted as already URL-safe.
    private static func downloadURL(repoID: String, filePath: String) throws -> URL {
        try apiURL(pathSuffix: "/\(repoID)/resolve/main/\(filePath)")
    }

    func info(repoID rawRepoID: String) async throws -> HuggingFaceRepositoryInfo {
        let repoID = try Self.validate(repoID: rawRepoID)
        let modelInfo = try await get(Self.apiURL(pathSuffix: "/api/models/\(repoID)"))
        var info = try Self.decodeModelInfo(modelInfo)
        guard !info.isGated else { throw HuggingFaceRepositoryError.gated }
        let tree = try await get(Self.apiURL(
            pathSuffix: "/api/models/\(repoID)/tree/main",
            query: [URLQueryItem(name: "recursive", value: "true")]
        ))
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
        let files = try entries
            .filter { $0.type == "file" && $0.path.hasSuffix(".gguf") }
            .map { entry in
                HuggingFaceGGUFFile(
                    path: entry.path,
                    sizeBytes: entry.size ?? 0,
                    sha256: entry.lfs?.oid,
                    downloadURL: try downloadURL(repoID: repoID, filePath: entry.path)
                )
            }
            .sorted { $0.sizeBytes < $1.sizeBytes }
        guard !files.isEmpty else { throw HuggingFaceRepositoryError.noGGUFFiles }
        return files
    }
}
