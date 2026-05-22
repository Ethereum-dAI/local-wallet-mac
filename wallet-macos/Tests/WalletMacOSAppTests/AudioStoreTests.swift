import AVFoundation
import XCTest
@testable import WalletMacOSApp

final class AudioStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: AudioStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AudioStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = AudioStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWriteAndReadBack() throws {
        let id = UUID()
        let sampleRate = 16_000
        let samples = (0..<sampleRate).map { index in
            Float(0.25 * sin(2 * .pi * 440 * Double(index) / Double(sampleRate)))
        }

        let result = try store.write(samples, sampleRate: sampleRate, id: id)
        XCTAssertEqual(result.filename, "\(id.uuidString).wav")

        let file = try AVAudioFile(forReading: store.url(forFilename: result.filename))
        XCTAssertEqual(Int(file.fileFormat.sampleRate), sampleRate)
        XCTAssertEqual(Int(file.length), sampleRate)
    }

    func testDeleteRemovesFile() throws {
        let id = UUID()
        let result = try store.write([0, 0.5, -0.5, 0], sampleRate: 16_000, id: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forFilename: result.filename).path))
        try store.delete(filename: result.filename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(forFilename: result.filename).path))
    }
}
