import XCTest
@testable import WalletMacOSApp

final class WaveformDownsamplerTests: XCTestCase {
    func testProducesExpectedNumberOfBars() {
        let samples = (0..<16_000).map { _ in Float.random(in: -1...1) }
        let bars = WaveformDownsampler.downsample(samples, bars: 40)
        XCTAssertEqual(bars.count, 40)
        bars.forEach {
            XCTAssertGreaterThanOrEqual($0, 0)
            XCTAssertLessThanOrEqual($0, 1)
        }
    }

    func testSilenceProducesZeros() {
        let samples = [Float](repeating: 0, count: 4_000)
        let bars = WaveformDownsampler.downsample(samples, bars: 40)
        XCTAssertEqual(bars, [Float](repeating: 0, count: 40))
    }

    func testSineHasNonZeroBars() {
        let sampleRate = 16_000
        let hz = 440
        let samples = (0..<sampleRate).map { index in
            Float(0.5 * sin(2 * .pi * Double(hz) * Double(index) / Double(sampleRate)))
        }
        let bars = WaveformDownsampler.downsample(samples, bars: 40)
        let mean = bars.reduce(0, +) / Float(bars.count)
        XCTAssertGreaterThan(mean, 0.4)
    }

    func testFormatToString() {
        let bars: [Float] = [0.1, 0.5, 1.0]
        XCTAssertEqual(WaveformDownsampler.toCommaSeparated(bars), "0.10,0.50,1.00")
    }
}
