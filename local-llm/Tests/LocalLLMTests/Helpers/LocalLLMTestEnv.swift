import Foundation
import AVFoundation

enum LocalLLMTestEnv {
    static let modelURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_K_M.gguf")

    static let mmprojURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/mmproj-gemma-4-E4B-it-bf16.gguf")

    static func filesExist(_ urls: URL...) -> Bool {
        urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func loadFixtureWAV(named name: String = "audio-prompt") throws -> (samples: [Float], sampleRate: Int) {
        let url = Bundle.module.url(forResource: name, withExtension: "wav")!
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: file.fileFormat.sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let length = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length)!
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else {
            return ([], Int(file.fileFormat.sampleRate))
        }
        return (Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))),
                Int(file.fileFormat.sampleRate))
    }
}
