import Foundation
import AVFoundation

// Writes mixed (system + mic) audio to a single interleaved 48 kHz stereo WAV.
//
// System audio (from SCStream) drives the clock: every pushSystem() call
// consumes a matching number of mic frames from a small FIFO, sums them,
// and writes exactly that many frames. If the mic FIFO is short, the gap is
// filled with system-only audio. If it grows beyond 1 s, the oldest frames
// are dropped — prevents unbounded memory if the mic is disconnected or
// delivering at a slightly higher rate.
final class MixingWriter {

    static let sampleRate: Double = 48_000
    static let channels: AVAudioChannelCount = 2

    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let lock = NSLock()

    // Interleaved mic FIFO: [L0, R0, L1, R1, ...]
    private var micFIFO: [Float] = []
    private let maxMicSamples = Int(sampleRate) * Int(channels)   // 1 s of stereo

    private(set) var framesWritten: Int = 0

    init(outputURL: URL) throws {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: true
        )!
        file = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )
    }

    // Called from SCStream callback queue.
    func pushSystem(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.isInterleaved,
              buffer.format.channelCount == Self.channels,
              let src = buffer.floatChannelData?[0]
        else { return }

        let frames = Int(buffer.frameLength)
        let samples = frames * Int(Self.channels)

        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        out.frameLength = AVAudioFrameCount(frames)
        guard let dst = out.floatChannelData?[0] else { return }

        lock.lock()
        let micTake = min(samples, micFIFO.count)
        for i in 0 ..< micTake {
            dst[i] = src[i] + micFIFO[i]
        }
        if micTake < samples {
            // Not enough mic data — fill remainder with system only
            for i in micTake ..< samples {
                dst[i] = src[i]
            }
        }
        if micTake > 0 {
            micFIFO.removeFirst(micTake)
        }
        lock.unlock()

        do {
            try file.write(from: out)
            framesWritten += frames
        } catch {
            fputs("MixingWriter: write error: \(error)\n", stderr)
        }
    }

    // Called from the mic tap.
    func pushMic(interleaved samples: UnsafePointer<Float>, frameCount: Int) {
        let count = frameCount * Int(Self.channels)
        lock.lock()
        micFIFO.reserveCapacity(micFIFO.count + count)
        for i in 0 ..< count {
            micFIFO.append(samples[i])
        }
        if micFIFO.count > maxMicSamples {
            micFIFO.removeFirst(micFIFO.count - maxMicSamples)
        }
        lock.unlock()
    }

    // Close the file. AVAudioFile finalises the WAV header on deinit.
    func finish() {
        // No explicit close; releasing the file handle via deinit is enough,
        // but the caller holds the reference — nothing else to do here.
    }
}
