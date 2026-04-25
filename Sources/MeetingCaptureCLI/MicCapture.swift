import Foundation
import AVFoundation

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
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat

    // (pointer to interleaved float32 stereo, frame count)
    var onSamples: ((UnsafePointer<Float>, Int) -> Void)?

    init() throws {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: MixingWriter.sampleRate,
            channels: MixingWriter.channels,
            interleaved: true
        )!

        inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "MicCapture", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No input device available (sample rate = 0)"
            ])
        }

        if inputFormat.sampleRate == targetFormat.sampleRate
            && inputFormat.channelCount == targetFormat.channelCount
            && inputFormat.isInterleaved == targetFormat.isInterleaved
            && inputFormat.commonFormat == targetFormat.commonFormat {
            converter = nil
        } else {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            if converter == nil {
                throw NSError(domain: "MicCapture", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "Could not build converter \(inputFormat) → \(targetFormat)"
                ])
            }
        }

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    var describedInputFormat: String {
        "\(Int(inputFormat.sampleRate)) Hz · \(inputFormat.channelCount) ch · \(inputFormat.commonFormat.rawValue == 1 ? "float32" : "pcm")"
    }

    // MARK: - Internal

    private func handle(_ inputBuffer: AVAudioPCMBuffer) {
        let outBuffer: AVAudioPCMBuffer

        if let converter {
            // Estimate output capacity
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(
                Double(inputBuffer.frameLength) * ratio
            ) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
            else { return }

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
            if status == .error || convError != nil { return }
            if out.frameLength == 0 { return }
            outBuffer = out
        } else {
            outBuffer = inputBuffer
        }

        guard let base = outBuffer.floatChannelData?[0] else { return }
        onSamples?(base, Int(outBuffer.frameLength))
    }
}
