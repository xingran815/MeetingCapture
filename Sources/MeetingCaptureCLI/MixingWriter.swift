import Foundation
import AVFoundation

// Writes mixed (system + mic) audio to interleaved 48 kHz mono int16 WAV files.
//
// Splits long recordings into ~30-minute chunks for fault tolerance.
// File naming: meeting.wav (part 1), meeting_part2.wav, meeting_part3.wav, ...
//
// System audio (from SCStream) drives the clock: every pushSystem() call
// consumes a matching number of mic frames from a small FIFO, sums them
// into a downmixed mono signal, and writes exactly that number of frames.
// If the mic FIFO is short, the gap is filled with system-only audio. If it
// grows beyond 1 s, the oldest frames are dropped — prevents unbounded
// memory if the mic is disconnected or delivering at a slightly higher rate.
//
// Internal mixing is float32; conversion to int16 happens at the write
// boundary. SCStream gives us stereo float32; we average L+R to mono.
// Mic is already mono. Mono int16 @ 48 kHz = ~5.6 MB/min — about 4× smaller
// than the previous stereo float32 layout, with no perceptible loss for
// transcription (Whisper downmixes to mono 16 kHz internally anyway).
final class MixingWriter {

    static let sampleRate: Double = 48_000

    // 30 minutes of frames at 48 kHz
    static let chunkFrameLimit: Int = 30 * 60 * Int(sampleRate)

    private var currentFile: AVAudioFile
    private let format: AVAudioFormat
    private let lock = NSLock()

    // Settings dict for AVAudioFile — interleaved mono int16 LPCM.
    private static let fileSettings: [String: Any] = [
        AVFormatIDKey:           kAudioFormatLinearPCM,
        AVSampleRateKey:         sampleRate,
        AVNumberOfChannelsKey:   1,
        AVLinearPCMBitDepthKey:  16,
        AVLinearPCMIsFloatKey:   false,
        AVLinearPCMIsBigEndianKey:    false,
        AVLinearPCMIsNonInterleaved:  false,
    ]

    // Mono mic FIFO: one float per frame.
    private var micFIFO: [Float] = []
    private let maxMicSamples = Int(sampleRate)   // 1 s of mono

    private(set) var framesWritten: Int = 0

    // Pause state: when true, pushSystem/pushMic drop their input. The wall-
    // clock gap during pause simply does not appear in the output WAV — audio
    // time stays contiguous, transcript timestamps reflect audio time.
    private var paused: Bool = false

    // Chunking state
    private let baseURL: URL
    private var chunkFrames: Int = 0
    private var partNumber: Int = 1
    private var allFiles: [URL] = []

    init(outputURL: URL) throws {
        self.baseURL = outputURL
        format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: true
        )!
        currentFile = try AVAudioFile(
            forWriting: outputURL,
            settings: Self.fileSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        allFiles.append(outputURL)
    }

    // Called from SCStream callback queue.
    func pushSystem(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.isInterleaved,
              buffer.format.channelCount == 2,
              let src = buffer.floatChannelData?[0]
        else { return }

        let frames = Int(buffer.frameLength)

        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        out.frameLength = AVAudioFrameCount(frames)
        guard let dst = out.int16ChannelData?[0] else { return }

        lock.lock()
        if paused {
            lock.unlock()
            return
        }
        let micTake = min(frames, micFIFO.count)
        // Downmix stereo system → mono by averaging L+R, sum mic where present,
        // then convert float → int16 with hard clamp.
        for f in 0 ..< frames {
            let sysMono = (src[2 * f] + src[2 * f + 1]) * 0.5
            let mic = f < micTake ? micFIFO[f] : 0
            let mixed = sysMono + mic
            let clamped = max(-1.0, min(1.0, mixed))
            dst[f] = Int16(clamped * 32767)
        }
        if micTake > 0 {
            micFIFO.removeFirst(micTake)
        }

        do {
            try currentFile.write(from: out)
            framesWritten += frames
            chunkFrames += frames

            // Rotate to new chunk if limit reached
            if chunkFrames >= Self.chunkFrameLimit {
                try rotateChunk()
            }
        } catch {
            fputs("MixingWriter: write error: \(error)\n", stderr)
        }

        lock.unlock()
    }

    // Called from the mic tap (or from EchoCanceller.onCleanMic when AEC is on).
    // `samples` is mono float32 — one float per frame.
    func pushMic(mono samples: UnsafePointer<Float>, frameCount: Int) {
        lock.lock()
        if paused {
            lock.unlock()
            return
        }
        micFIFO.reserveCapacity(micFIFO.count + frameCount)
        for i in 0 ..< frameCount {
            micFIFO.append(samples[i])
        }
        if micFIFO.count > maxMicSamples {
            micFIFO.removeFirst(micFIFO.count - maxMicSamples)
        }
        lock.unlock()
    }

    // Close current chunk and start a new one.
    // Must be called with lock held.
    private func rotateChunk() throws {
        // Reassigning currentFile triggers deinit of old file, which finalizes WAV header
        let newURL = nextChunkURL()
        currentFile = try AVAudioFile(
            forWriting: newURL,
            settings: Self.fileSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        allFiles.append(newURL)
        chunkFrames = 0
        partNumber += 1
    }

    // Generate URL for next chunk: base_partN.wav
    private func nextChunkURL() -> URL {
        let basePath = baseURL.deletingPathExtension().path
        let ext = baseURL.pathExtension
        return URL(fileURLWithPath: "\(basePath)_part\(partNumber + 1).\(ext)")
    }

    // Return list of all written files.
    // Note: WAV headers are finalized when this MixingWriter is deallocated.
    func finish() -> [URL] {
        return allFiles
    }

    /// Toggle pause state. Returns the new state (true = paused).
    /// While paused, pushSystem/pushMic drop their input and the mic FIFO
    /// stops draining; the FIFO's 1-s cap prevents unbounded growth across
    /// the toggle.
    @discardableResult
    func togglePause() -> Bool {
        lock.lock()
        paused.toggle()
        // When pausing, drop any buffered mic samples so they don't get
        // spliced in when we resume.
        if paused {
            micFIFO.removeAll(keepingCapacity: true)
        }
        let nowPaused = paused
        lock.unlock()
        return nowPaused
    }
}
