import AVFoundation
import Foundation

struct AudioStore {
    struct WriteResult {
        let url: URL
        let filename: String
    }

    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(directory: appSupport
            .appendingPathComponent("LocalWallet", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true))
    }

    func url(forFilename filename: String) -> URL {
        directory.appendingPathComponent(filename, isDirectory: false)
    }

    func write(_ samples: [Float], sampleRate: Int, id: UUID) throws -> WriteResult {
        let filename = "\(id.uuidString).wav"
        let url = directory.appendingPathComponent(filename, isDirectory: false)

        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: Double(sampleRate),
                                        channels: 1,
                                        interleaved: false)!
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url,
                                   settings: outputSettings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0], !samples.isEmpty {
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
        return WriteResult(url: url, filename: filename)
    }

    func delete(filename: String) throws {
        let url = url(forFilename: filename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
