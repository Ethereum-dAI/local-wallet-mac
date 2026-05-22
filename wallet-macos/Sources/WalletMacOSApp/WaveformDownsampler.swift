import Foundation

enum WaveformDownsampler {
    static func downsample(_ samples: [Float], bars: Int) -> [Float] {
        guard bars > 0 else { return [] }
        guard !samples.isEmpty else { return [Float](repeating: 0, count: bars) }

        let windowSize = max(1, samples.count / bars)
        var result: [Float] = []
        result.reserveCapacity(bars)

        for index in 0..<bars {
            let start = index * windowSize
            let end = min(samples.count, start + windowSize)
            if start >= end {
                result.append(0)
                continue
            }

            var peak: Float = 0
            for sample in samples[start..<end] {
                peak = max(peak, abs(sample))
            }
            result.append(min(peak, 1))
        }

        return result
    }

    static func toCommaSeparated(_ bars: [Float]) -> String {
        bars.map { String(format: "%.2f", $0) }.joined(separator: ",")
    }

    static func parse(_ string: String) -> [Float] {
        string.split(separator: ",").compactMap { Float($0) }
    }
}
