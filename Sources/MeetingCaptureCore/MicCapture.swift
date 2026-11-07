import AVFoundation
import Foundation

// Microphone capture via AVAudioEngine.
//
// Installs a tap on the input node, converts each buffer to 48 kHz stereo
// float32 interleaved (matching the system-audio format from SCStream),
// and hands the samples to the provided callback.
//
// Requires Microphone permission. Throws from start() if the engine can't
// open the input device — caller should treat that as non-fatal and
// proceed system-audio-only.
final class MicCapture {

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    /// Only the tap's thread touches it.
    private let converter: MicFormatConverter
    /// What the device reported at start, for the startup line only.
    private let inputFormat: AVAudioFormat

    /// Start, stop and device-change restarts run one at a time here.
    private let control = DispatchQueue(label: "MeetingCapture.mic.control")
    private var observer: NSObjectProtocol?
    private var running = false
    /// How many times the mic came back after a device change, for tests and the note.
    private(set) var restarts = 0

    // (pointer to interleaved float32 mono, frame count)
    var onSamples: ((UnsafePointer<Float>, Int) -> Void)?
    /// A line for the user when the input device changes mid-recording.
    var onDeviceChange: ((String) -> Void)?

    init() throws {
        // Mic emits MONO at 48 kHz, one track of TrackWriter's two.
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: TrackWriter.sampleRate,
            channels: 1,
            interleaved: true
        )!
        converter = MicFormatConverter(target: targetFormat)

        inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(
                domain: "MicCapture", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "No input device available (sample rate = 0)"
                ])
        }
        installTap()
    }

    /// No fixed format: the tap takes whatever the device delivers. Passing the format read
    /// at start crashed a real recording (a monitor unplugged, so 2 ch 44.1 kHz input):
    /// installTap raises an Objective-C exception on a mismatch, which Swift can't catch.
    /// Each buffer is converted from its own format.
    private func installTap() {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
    }

    func start() throws {
        try control.sync {
            // A device plugged or unplugged mid-call stops the engine, and without this the
            // mic stayed silent for the rest of the recording (M3.2, from the user's report).
            // Registered before the start, so no change slips in between.
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.control.async { self?.restartAfterDeviceChange() }
            }
            running = true
            engine.prepare()
            do {
                try engine.start()
            } catch {
                running = false
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
                throw error
            }
        }
    }

    func stop() {
        control.sync {
            running = false
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Runs on `control`. The new device's format is taken as it comes. With no input device
    /// at all, the mic waits: plugging one in posts another change, which lands here again.
    /// The gap is silence on the mic track, since system audio drives the clock, so the
    /// tracks stay in step. The echo's delay may change with the device; EchoRemover's lag
    /// track notes that when it does.
    func restartAfterDeviceChange() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onDeviceChange?("mic input gone; it resumes when an input device comes back")
            return
        }
        installTap()
        engine.prepare()
        do {
            try engine.start()
            restarts += 1
            onDeviceChange?("mic input changed, now \(Self.describe(format)); recording goes on")
        } catch {
            onDeviceChange?("mic couldn't restart after a device change: \(error.localizedDescription)")
        }
    }

    static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz · \(format.channelCount) ch · \(format.commonFormat.rawValue == 1 ? "float32" : "pcm")"
    }

    var describedInputFormat: String { Self.describe(inputFormat) }

    // MARK: - Internal

    func handle(_ inputBuffer: AVAudioPCMBuffer) {
        guard let out = converter.convert(inputBuffer), let base = out.floatChannelData?[0] else { return }
        onSamples?(base, Int(out.frameLength))
    }
}

/// Converts mic buffers, in whatever format they arrive, to the track's 48 kHz mono float32.
/// The converter is rebuilt when the format changes, as when a device is plugged or unplugged
/// (a monitor unplugged gave 2 ch 44.1 kHz and crashed a recording, M3.2). A buffer it can't
/// convert gives nil, never a crash. Apart from MicCapture so it's tested without a mic.
final class MicFormatConverter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    init(target: AVAudioFormat) { self.target = target }

    /// True when a buffer in `format` can go out as is.
    static func needsNoConversion(_ format: AVAudioFormat, to target: AVAudioFormat) -> Bool {
        format.sampleRate == target.sampleRate && format.channelCount == target.channelCount
            && format.isInterleaved == target.isInterleaved && format.commonFormat == target.commonFormat
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = inputBuffer.format
        guard format.sampleRate > 0, inputBuffer.frameLength > 0 else { return nil }
        if Self.needsNoConversion(format, to: target) { return inputBuffer }
        if converterInput != format {
            converter = AVAudioConverter(from: format, to: target)
            converterInput = format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error || convError != nil || out.frameLength == 0 { return nil }
        return out
    }
}
