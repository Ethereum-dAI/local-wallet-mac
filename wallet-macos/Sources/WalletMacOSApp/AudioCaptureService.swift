@preconcurrency import AVFoundation
import Combine
import Foundation
import OSLog

private let audioCaptureLogger = Logger(subsystem: "ai.ethereum.localwallet.demo", category: "AudioCapture")

private final class AudioSampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func append(_ newSamples: [Float], limit: Int) -> (count: Int, reachedLimit: Bool) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        if samples.count > limit {
            samples.removeSubrange(limit..<samples.count)
        }
        let count = samples.count
        lock.unlock()
        return (count, count >= limit)
    }

    func snapshotAndClear() -> [Float] {
        lock.lock()
        let copy = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        return copy
    }
}

private enum AudioPCMBufferSamples {
    static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else {
            return []
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return [] }
            return monoSamples(
                frameLength: frameLength,
                channelCount: channelCount,
                isInterleaved: buffer.format.isInterleaved,
                read: { channel, frame in channelData[channel][frame] },
                readInterleaved: { offset in channelData[0][offset] }
            )
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return [] }
            let scale = 1 / Float(Int16.max)
            return monoSamples(
                frameLength: frameLength,
                channelCount: channelCount,
                isInterleaved: buffer.format.isInterleaved,
                read: { channel, frame in Float(channelData[channel][frame]) * scale },
                readInterleaved: { offset in Float(channelData[0][offset]) * scale }
            )
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData else { return [] }
            let scale = 1 / Float(Int32.max)
            return monoSamples(
                frameLength: frameLength,
                channelCount: channelCount,
                isInterleaved: buffer.format.isInterleaved,
                read: { channel, frame in Float(channelData[channel][frame]) * scale },
                readInterleaved: { offset in Float(channelData[0][offset]) * scale }
            )
        default:
            return []
        }
    }

    private static func monoSamples(
        frameLength: Int,
        channelCount: Int,
        isInterleaved: Bool,
        read: (_ channel: Int, _ frame: Int) -> Float,
        readInterleaved: (_ offset: Int) -> Float
    ) -> [Float] {
        if channelCount == 1 {
            return (0..<frameLength).map { frame in read(0, frame) }
        }

        var samples = [Float](repeating: 0, count: frameLength)
        if isInterleaved {
            for frame in 0..<frameLength {
                var sum: Float = 0
                let frameOffset = frame * channelCount
                for channel in 0..<channelCount {
                    sum += readInterleaved(frameOffset + channel)
                }
                samples[frame] = sum / Float(channelCount)
            }
        } else {
            for channel in 0..<channelCount {
                for frame in 0..<frameLength {
                    samples[frame] += read(channel, frame)
                }
            }
            let scale = 1 / Float(channelCount)
            for frame in 0..<frameLength {
                samples[frame] *= scale
            }
        }

        return samples
    }
}

private enum AudioSampleBufferSamples {
    struct CapturedAudio {
        let samples: [Float]
        let sampleRate: Int
        let formatDescription: String
    }

    static func monoSamples(from sampleBuffer: CMSampleBuffer) -> CapturedAudio? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = streamDescription.pointee
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let channelCount = Int(asbd.mChannelsPerFrame)
        guard sampleCount > 0, channelCount > 0, asbd.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }

        let maxBuffers = max(1, channelCount)
        let audioBufferListSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * (maxBuffers - 1)
        let audioBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: audioBufferListSize)
        defer { audioBufferList.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return nil
        }

        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

        var samples = [Float](repeating: 0, count: sampleCount)
        if isNonInterleaved {
            for channel in 0..<min(channelCount, buffers.count) {
                guard let data = buffers[channel].mData else { continue }
                addChannel(data: data,
                           channel: channel,
                           channelCount: channelCount,
                           frameCount: sampleCount,
                           bitsPerChannel: bitsPerChannel,
                           isFloat: isFloat,
                           isSignedInteger: isSignedInteger,
                           into: &samples)
            }
        } else {
            guard let data = buffers.first?.mData else {
                return nil
            }
            addInterleaved(data: data,
                           channelCount: channelCount,
                           frameCount: sampleCount,
                           bitsPerChannel: bitsPerChannel,
                           isFloat: isFloat,
                           isSignedInteger: isSignedInteger,
                           into: &samples)
        }

        let scale = 1 / Float(channelCount)
        for index in samples.indices {
            samples[index] *= scale
        }

        let description = "rate=\(Int(asbd.mSampleRate.rounded())) channels=\(channelCount) bits=\(bitsPerChannel) float=\(isFloat) signedInt=\(isSignedInteger) nonInterleaved=\(isNonInterleaved)"
        return CapturedAudio(samples: samples,
                             sampleRate: Int(asbd.mSampleRate.rounded()),
                             formatDescription: description)
    }

    private static func addChannel(
        data: UnsafeMutableRawPointer,
        channel: Int,
        channelCount: Int,
        frameCount: Int,
        bitsPerChannel: Int,
        isFloat: Bool,
        isSignedInteger: Bool,
        into samples: inout [Float]
    ) {
        guard channel < channelCount else { return }
        for frame in 0..<frameCount {
            samples[frame] += readSample(data: data,
                                         sampleIndex: frame,
                                         bitsPerChannel: bitsPerChannel,
                                         isFloat: isFloat,
                                         isSignedInteger: isSignedInteger)
        }
    }

    private static func addInterleaved(
        data: UnsafeMutableRawPointer,
        channelCount: Int,
        frameCount: Int,
        bitsPerChannel: Int,
        isFloat: Bool,
        isSignedInteger: Bool,
        into samples: inout [Float]
    ) {
        for frame in 0..<frameCount {
            let frameOffset = frame * channelCount
            for channel in 0..<channelCount {
                samples[frame] += readSample(data: data,
                                             sampleIndex: frameOffset + channel,
                                             bitsPerChannel: bitsPerChannel,
                                             isFloat: isFloat,
                                             isSignedInteger: isSignedInteger)
            }
        }
    }

    private static func readSample(
        data: UnsafeMutableRawPointer,
        sampleIndex: Int,
        bitsPerChannel: Int,
        isFloat: Bool,
        isSignedInteger: Bool
    ) -> Float {
        if isFloat, bitsPerChannel == 32 {
            return data.assumingMemoryBound(to: Float.self)[sampleIndex]
        }
        if isFloat, bitsPerChannel == 64 {
            return Float(data.assumingMemoryBound(to: Double.self)[sampleIndex])
        }
        if isSignedInteger, bitsPerChannel == 16 {
            return Float(data.assumingMemoryBound(to: Int16.self)[sampleIndex]) / Float(Int16.max)
        }
        if isSignedInteger, bitsPerChannel == 32 {
            return Float(data.assumingMemoryBound(to: Int32.self)[sampleIndex]) / Float(Int32.max)
        }
        return 0
    }
}

private enum AudioFormatDebug {
    static func describe(_ format: AVAudioFormat) -> String {
        "rate=\(Int(format.sampleRate.rounded())) channels=\(format.channelCount) common=\(String(describing: format.commonFormat)) interleaved=\(format.isInterleaved)"
    }
}

enum AudioResampler {
    static func resample(_ samples: [Float], sourceSampleRate: Int, targetSampleRate: Int) -> [Float] {
        guard !samples.isEmpty,
              sourceSampleRate > 0,
              targetSampleRate > 0,
              sourceSampleRate != targetSampleRate else {
            return samples
        }

        let targetCount = max(1, Int((Double(samples.count) * Double(targetSampleRate) / Double(sourceSampleRate)).rounded()))
        var output = [Float](repeating: 0, count: targetCount)
        let sourceStep = Double(sourceSampleRate) / Double(targetSampleRate)

        for index in 0..<targetCount {
            let sourcePosition = Double(index) * sourceStep
            let lowerIndex = min(Int(sourcePosition), samples.count - 1)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            output[index] = samples[lowerIndex] + (samples[upperIndex] - samples[lowerIndex]) * fraction
        }

        return output
    }
}

private final class AudioCaptureSampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias SampleHandler = @Sendable (_ totalSamples: Int, _ sampleRate: Int, _ formatDescription: String, _ reachedLimit: Bool) -> Void

    private let accumulator: AudioSampleAccumulator
    private let maxDurationSeconds: TimeInterval
    private let sampleHandler: SampleHandler

    init(accumulator: AudioSampleAccumulator,
         maxDurationSeconds: TimeInterval,
         sampleHandler: @escaping SampleHandler) {
        self.accumulator = accumulator
        self.maxDurationSeconds = maxDurationSeconds
        self.sampleHandler = sampleHandler
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let capturedAudio = AudioSampleBufferSamples.monoSamples(from: sampleBuffer) else {
            return
        }

        let sampleLimit = Int(maxDurationSeconds * Double(capturedAudio.sampleRate))
        let appendResult = accumulator.append(capturedAudio.samples, limit: sampleLimit)
        sampleHandler(appendResult.count,
                      capturedAudio.sampleRate,
                      capturedAudio.formatDescription,
                      appendResult.reachedLimit)
    }
}

@MainActor
final class AudioCaptureService: ObservableObject {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case engineStartFailed(String)
        case converterUnavailable
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is blocked. Open System Settings > Privacy & Security > Microphone."
            case .engineStartFailed(let message):
                return "Audio engine failed to start: \(message)"
            case .converterUnavailable:
                return "Could not create an audio format converter."
            case .emptyRecording:
                return "No microphone audio was captured. Check the selected input device and try again."
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

    private let accumulator = AudioSampleAccumulator()
    private let captureQueue = DispatchQueue(label: "ai.ethereum.localwallet.demo.audio-capture")
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var captureDelegate: AudioCaptureSampleDelegate?
    private var targetSampleRate = 16_000
    private var sourceSampleRate = 16_000
    private var loggedTapCallbacks = 0
    private let maxDurationSeconds: TimeInterval = 120

    func start(targetSampleRate: Int) async {
        switch state {
        case .idle, .finished, .failed:
            break
        case .requestingPermission, .recording, .finalizing:
            return
        }

        self.targetSampleRate = targetSampleRate
        state = .requestingPermission
        let granted = await Self.requestPermission()
        guard case .requestingPermission = state else {
            return
        }
        guard granted else {
            state = .failed(CaptureError.permissionDenied.localizedDescription)
            return
        }

        do {
            try startEngine()
            state = .recording
        } catch {
            cleanupEngine()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard case .recording = state else { return }
        state = .finalizing

        cleanupEngine()

        let rawSamples = accumulator.snapshotAndClear()
        let sourceRate = sourceSampleRate
        let rate = targetSampleRate
        audioCaptureLogger.info("Stopping capture rawSamples=\(rawSamples.count) sourceRate=\(sourceRate) targetRate=\(rate)")
        let recording = await Task.detached(priority: .userInitiated) {
            let samples = AudioResampler.resample(rawSamples, sourceSampleRate: sourceRate, targetSampleRate: rate)
            let bars = WaveformDownsampler.downsample(samples, bars: 40)
            let duration = Double(samples.count) / Double(rate)
            return Recording(samples: samples,
                             sampleRate: rate,
                             durationSeconds: duration,
                             waveformBars: bars)
        }.value

        if recording.samples.isEmpty {
            audioCaptureLogger.error("Capture finished with no samples")
            state = .failed(CaptureError.emptyRecording.localizedDescription)
        } else {
            audioCaptureLogger.info("Capture finished samples=\(recording.samples.count) duration=\(recording.durationSeconds)")
            state = .finished(recording)
        }
    }

    func cancel() {
        cleanupEngine()
        accumulator.reset()
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
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.converterUnavailable
        }

        accumulator.reset()
        elapsed = 0
        loggedTapCallbacks = 0

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.converterUnavailable
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.converterUnavailable
        }

        let delegate = AudioCaptureSampleDelegate(accumulator: accumulator,
                                                  maxDurationSeconds: maxDurationSeconds) { [weak self] totalSamples, sampleRate, formatDescription, reachedLimit in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sourceSampleRate = sampleRate
                if self.loggedTapCallbacks < 5 {
                    self.loggedTapCallbacks += 1
                    audioCaptureLogger.info(
                        "Capture callback totalSamples=\(totalSamples) sampleRate=\(sampleRate) format=\(formatDescription, privacy: .public)"
                    )
                }
                self.elapsed = Double(totalSamples) / Double(sampleRate)
                if reachedLimit {
                    await self.stop()
                }
            }
        }
        output.setSampleBufferDelegate(delegate, queue: captureQueue)
        session.addOutput(output)
        session.commitConfiguration()

        captureSession = session
        audioOutput = output
        captureDelegate = delegate

        audioCaptureLogger.info("Starting capture device=\(device.localizedName, privacy: .public) uniqueID=\(device.uniqueID, privacy: .public)")
        captureQueue.sync {
            session.startRunning()
        }
        guard session.isRunning else {
            cleanupEngine()
            throw CaptureError.engineStartFailed("AVCaptureSession did not start running.")
        }
    }

    private func cleanupEngine() {
        let session = captureSession
        captureSession = nil
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        audioOutput = nil
        captureDelegate = nil

        if let session, session.isRunning {
            captureQueue.sync {
                session.stopRunning()
            }
        }
    }
}
