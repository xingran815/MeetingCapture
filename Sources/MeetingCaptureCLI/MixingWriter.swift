import Foundation
import AVFoundation

// Writes mixed (system + mic) audio to a single interleaved 48 kHz stereo WAV.
//
// System audio (from SCStream) drives the clock: every pushSystem() call
// consumes a matching number of mic frames from a small FIFO, sums them
// equally into both stereo channels, and writes exactly that many frames.
// If the mic FIFO is short, the gap is filled with system-only audio. If it
// grows beyond 1 s, the oldest frames are dropped — prevents unbounded
// memory if the mic is disconnected or delivering at a slightly higher rate.
//
// Mic input is mono (one float per frame). MicCapture emits mono; if AEC is
// enabled, EchoCanceller's clean output is mono. We expand to stereo here.
final class MixingWriter {

    static let sampleRate: Double = 48_000
    static let channels: AVAudioChannelCount = 2

    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let lock = NSLock()

    // Mono mic FIFO: one float per frame.
    private var micFIFO: [Float] = []
    private let maxMicSamples = Int(sampleRate)   // 1 s of mono

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

        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        out.frameLength = AVAudioFrameCount(frames)
        guard let dst = out.floatChannelData?[0] else { return }

        lock.lock()
        let micTake = min(frames, micFIFO.count)
        // Frames where we have mic data: sum mono mic into both stereo channels.
        for f in 0 ..< micTake {
            let m = micFIFO[f]
            dst[2 * f]     = src[2 * f]     + m
            dst[2 * f + 1] = src[2 * f + 1] + m
        }
        // Remaining frames: system only.
        for f in micTake ..< frames {
            dst[2 * f]     = src[2 * f]
            dst[2 * f + 1] = src[2 * f + 1]
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

    // Called from the mic tap (or from EchoCanceller.onCleanMic when AEC is on).
    // `samples` is mono float32 — one float per frame.
    func pushMic(mono samples: UnsafePointer<Float>, frameCount: Int) {
        lock.lock()
        micFIFO.reserveCapacity(micFIFO.count + frameCount)
        for i in 0 ..< frameCount {
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
