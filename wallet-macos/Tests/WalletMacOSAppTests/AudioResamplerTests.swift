import XCTest
@testable import WalletMacOSApp

final class AudioResamplerTests: XCTestCase {
    func testDownsamplesToTargetRate() {
        let samples = (0..<48_000).map { Float($0) }
        let output = AudioResampler.resample(samples, sourceSampleRate: 48_000, targetSampleRate: 16_000)

        XCTAssertEqual(output.count, 16_000)
        XCTAssertEqual(output[0], 0)
        XCTAssertEqual(output[1], 3)
        XCTAssertEqual(output[2], 6)
    }

    func testUpsamplesWithLinearInterpolation() {
        let output = AudioResampler.resample([0, 10], sourceSampleRate: 1, targetSampleRate: 2)

        XCTAssertEqual(output, [0, 5, 10, 10])
    }

    func testMatchingRatesReturnInput() {
        let samples: [Float] = [0.1, -0.2, 0.3]

        XCTAssertEqual(AudioResampler.resample(samples, sourceSampleRate: 16_000, targetSampleRate: 16_000), samples)
    }
}
