import Foundation

// MARK: - Dataset model
//
// Mirrors the JSON produced by scripts/convert-userop-eval-dataset.py from the
// evals-local-llm combined benchmark (tests.combined.yaml). Only cases whose
// gold is a single `transfer` or `swap` tool call are in that JSON — see the
// conversion script for the exact eligibility rule and the excluded-category
// breakdown.

struct UserOpTurn: Codable {
    let role: String
    let content: String
}

struct UserOpDatasetCase: Codable {
    let id: String
    let category: String
    let protocolName: String?
    let language: String?
    let queryType: String?
    let turns: [UserOpTurn]
    let expectedSummary: String?
    /// Each element is the flat string-keyed args dict for one gold tool call,
    /// including "tool" and "chainId" alongside the tool-specific fields
    /// (to/amount/token or from_token/to_token/amount/amount_side). The
    /// conversion script guarantees exactly one element per case.
    let expectedCalls: [[String: String]]

    enum CodingKeys: String, CodingKey {
        case id, category, turns
        case protocolName = "protocol"
        case language
        case queryType = "query_type"
        case expectedSummary = "expected_summary"
        case expectedCalls = "expected_calls"
    }
}

struct UserOpDataset: Codable {
    let schema: String
    let cases: [UserOpDatasetCase]
}

func loadUserOpDataset() throws -> UserOpDataset {
    guard let url = Bundle.module.url(forResource: "userop_cases",
                                       withExtension: "json",
                                       subdirectory: "Dataset") else {
        throw NSError(domain: "wallet-eval", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Dataset/userop_cases.json not found in bundle"])
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(UserOpDataset.self, from: data)
}
