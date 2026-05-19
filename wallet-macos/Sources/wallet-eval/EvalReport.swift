import Foundation

struct EvalEntry: Codable {
    let subcommand: String
    let label: String
    let metric: String
    let mean: Double
    let stddev: Double
    let samples: Int
}

final class EvalReport: @unchecked Sendable {
    static let shared = EvalReport()
    var jsonPath: String? = nil
    private var entries: [EvalEntry] = []

    func record(_ entry: EvalEntry) {
        entries.append(entry)
        flush()
    }

    func recordRaw(subcommand: String, label: String, value: Double, samples: Int, metric: String) {
        record(EvalEntry(subcommand: subcommand, label: label, metric: metric, mean: value, stddev: 0, samples: samples))
    }

    func flush() {
        guard let path = jsonPath else { return }
        let payload: [String: Any] = [
            "schema": "wallet-eval/v1",
            "entries": entries.map { e -> [String: Any] in
                ["subcommand": e.subcommand, "label": e.label, "metric": e.metric,
                 "mean": e.mean, "stddev": e.stddev, "samples": e.samples]
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

func summaryStats(_ samples: [Double]) -> (mean: Double, stddev: Double) {
    guard !samples.isEmpty else { return (0, 0) }
    let mean = samples.reduce(0, +) / Double(samples.count)
    let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
    return (mean, sqrt(variance))
}
