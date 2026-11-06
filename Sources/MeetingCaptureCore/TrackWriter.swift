import AVFoundation
import Foundation

// Writes two-track, interleaved, 48 kHz int16 WAV files: channel 1 is the mic, and
// channel 2 is system audio. The tracks stay apart so the mic can be labelled `You`
// and only the system track goes through speaker detection.
//
// Splits long recordings into ~30-minute chunks for fault tolerance.
// File naming: meeting.wav (part 1), meeting_part2.wav, meeting_part3.wav, ...
//
// System audio (from SCStream) drives the clock: every pushSystem() call consumes
// a matching number of mic frames from a small FIFO and writes exactly that number
// of frames. If the FIFO is short, the rest of the mic track is silence. If it
// grows beyond 1 s, the oldest frames are dropped, which bounds memory if the mic
// delivers at a slightly higher rate.
//
// Samples are float32 until the write, where they're clamped and converted to
// int16. SCStream gives stereo float32, averaged L+R to one track. Two int16 tracks
// at 48 kHz are about 11.5 MB/min; that's only until the WAV becomes an M4A.
final class TrackWriter {

    static let sampleRate: Double = 48_000

    // 30 minutes of frames at 48 kHz. Tests inject a shorter limit rather than wait.
    static let defaultChunkFrameLimit: Int = 30 * 60 * Int(sampleRate)
    private let chunkFrameLimit: Int

    private var currentFile: AVAudioFile
    private let format: AVAudioFormat
    private let lock = NSLock()

    // Settings dict for AVAudioFile — interleaved two-track int16 LPCM.
    private static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    // Mono mic FIFO: one float per frame.
    private var micFIFO: [Float] = []
    private let maxMicSamples = Int(sampleRate)  // 1 s of mono

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
    // 0 means unlimited; set to prevent spurious chunks at the recording boundary.
    private let targetDurationFrames: Int

    init(
        outputURL: URL,
        targetDurationSeconds: Double = 0,
        chunkFrameLimit: Int = TrackWriter.defaultChunkFrameLimit
    ) throws {
        self.baseURL = outputURL
        self.chunkFrameLimit = chunkFrameLimit
        self.targetDurationFrames =
            targetDurationSeconds > 0
            ? Int(targetDurationSeconds * Self.sampleRate)
            : 0
        format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 2,
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
        for f in 0..<frames {
            let system = (src[2 * f] + src[2 * f + 1]) * 0.5
            let mic = f < micTake ? micFIFO[f] : 0
            dst[2 * f] = Int16(max(-1.0, min(1.0, mic)) * 32767)
            dst[2 * f + 1] = Int16(max(-1.0, min(1.0, system)) * 32767)
        }
        if micTake > 0 {
            micFIFO.removeFirst(micTake)
        }

        do {
            try currentFile.write(from: out)
            framesWritten += frames
            chunkFrames += frames

            // Rotate to new chunk if limit reached
            if chunkFrames >= chunkFrameLimit {
                try rotateChunk()
            }
        } catch {
            fputs("TrackWriter: write error: \(error)\n", stderr)
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
        for i in 0..<frameCount {
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
        // Skip rotation if we've already written the full target duration.
        // Prevents a spurious short chunk when safety cap == chunk size.
        if targetDurationFrames > 0 && framesWritten >= targetDurationFrames { return }
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
    // Note: WAV headers are finalized when this TrackWriter is deallocated.
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
