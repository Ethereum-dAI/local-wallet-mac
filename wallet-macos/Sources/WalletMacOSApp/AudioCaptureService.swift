import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioCaptureService: ObservableObject {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case engineStartFailed(String)
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is blocked. Open System Settings > Privacy & Security > Microphone."
            case .engineStartFailed(let message):
                return "Audio engine failed to start: \(message)"
            case .converterUnavailable:
                return "Could not create an audio format converter."
            }
        }
    }

    struct Recording {
        let samples: [Float]
        let sampleRate: Int
        let durationSeconds: TimeInterval
        let waveformBars: [Float]
    }

    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case finalizing
        case finished(Recording)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.requestingPermission, .requestingPermission), (.recording, .recording), (.finalizing, .finalizing):
                return true
            case (.failed(let left), .failed(let right)):
                return left == right
            case (.finished(let left), .finished(let right)):
                return left.samples == right.samples && left.sampleRate == right.sampleRate
            default:
                return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var ringBuffer: [Float] = []
    private var targetSampleRate = 16_000
    private let maxDurationSeconds: TimeInterval = 120

    func start(targetSampleRate: Int) async {
        self.targetSampleRate = targetSampleRate
        state = .requestingPermission
        let granted = await Self.requestPermission()
        guard granted else {
            state = .failed(CaptureError.permissionDenied.localizedDescription)
            return
        }

        do {
            try startEngine()
            state = .recording
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard case .recording = state else { return }
        state = .finalizing

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let samples = ringBuffer
        let rate = targetSampleRate
        let recording = await Task.detached(priority: .userInitiated) {
            let bars = WaveformDownsampler.downsample(samples, bars: 40)
            let duration = Double(samples.count) / Double(rate)
            return Recording(samples: samples,
                             sampleRate: rate,
                             durationSeconds: duration,
                             waveformBars: bars)
        }.value

        ringBuffer.removeAll(keepingCapacity: false)
        state = .finished(recording)
    }

    func cancel() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        ringBuffer.removeAll(keepingCapacity: false)
        state = .idle
        elapsed = 0
    }

    private static func requestPermission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            return true
        }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startEngine() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Double(targetSampleRate),
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter
        ringBuffer = []
        elapsed = 0

        let sampleLimit = Int(maxDurationSeconds * Double(targetSampleRate))
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * Double(self.targetSampleRate) / inputFormat.sampleRate + 8)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrames) else {
                return
            }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let pointer = outputBuffer.floatChannelData?[0] else {
                return
            }

            let frameLength = Int(outputBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: pointer, count: frameLength))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ringBuffer.append(contentsOf: samples)
                self.elapsed = Double(self.ringBuffer.count) / Double(self.targetSampleRate)
                if self.ringBuffer.count >= sampleLimit {
                    await self.stop()
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
    }
}
