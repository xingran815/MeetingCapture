import AVFoundation
import Foundation

// WAV → M4A, then delete the WAV, but only once the M4A is proven good. A failed
// conversion must never lose a recording.
protocol AudioEncoding {
    func encode(wav: URL, to m4a: URL) throws
}

struct AACEncoder: AudioEncoding {
    static let bitRatePerChannel = 64_000

    func encode(wav: URL, to m4a: URL) throws {
        let input = try AVAudioFile(forReading: wav)
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: Self.bitRatePerChannel * channels,
        ]
        // Scoped so the output closes, which finishes the file, before anyone checks it.
        let output = try AVAudioFile(
            forWriting: m4a, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let capacity: AVAudioFrameCount = 48_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw CocoaError(.fileWriteUnknown)
        }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: capacity)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}

enum AudioArchive {

    /// AAC adds a little priming, so lengths never match exactly.
    static let durationTolerance = 0.5

    enum Outcome: Equatable {
        case archived(m4a: URL)
        case keptWAV(reason: String)
    }

    /// Why this M4A can't replace the WAV, or nil if it can.
    static func problem(withM4A m4a: URL, comparedTo wav: URL) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: m4a.path)
        guard let size = attributes?[.size] as? Int else { return "the M4A wasn't created" }
        guard size > 0 else { return "the M4A is empty" }
        guard let original = RecordingFiles.duration(ofAudioAt: wav.path) else { return "the WAV couldn't be read" }
        guard let encoded = RecordingFiles.duration(ofAudioAt: m4a.path) else { return "the M4A couldn't be read" }
        guard original > 0 else { return "the WAV's header says it holds no audio" }
        guard !headerUndercounts(wav) else { return "the WAV holds more audio than its header says" }
        guard abs(original - encoded) <= durationTolerance else {
            return String(format: "the M4A is %.1f s long but the WAV is %.1f s", encoded, original)
        }
        return nil
    }

    /// More than a header's worth of bytes beyond what the WAV declares.
    private static let headerSlack: Int64 = 64 * 1024

    /// Finding from the deep review: the length check compares against the header, so
    /// a crashed WAV that declares no audio matched an empty M4A and was deleted. The
    /// size on disk is the one figure a crash can't have left stale.
    private static func headerUndercounts(_ wav: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: wav),
            let size = (try? FileManager.default.attributesOfItem(atPath: wav.path))?[.size] as? Int
        else { return true }
        let bytesPerFrame = Int64(file.fileFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return false }
        return Int64(size) > file.length * bytesPerFrame + headerSlack
    }

    /// The M4A is built under a temporary name and only moved into place once proven,
    /// so a failure can't touch a file already called `<base>.m4a`, and neither can a
    /// success: an existing one is left alone and the WAV stays.
    static func archive(wav: URL, encoder: AudioEncoding = AACEncoder()) -> Outcome {
        let files = FileManager.default
        let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
        guard !files.fileExists(atPath: m4a.path) else {
            return .keptWAV(reason: "\(m4a.lastPathComponent) already exists, so it wasn't replaced")
        }
        // A crashed WAV reads as empty until this runs. If it can't run, the proof refuses it.
        _ = try? WAVRepair.repairHeader(at: wav)

        let temporary = wav.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { try? files.removeItem(at: temporary) }
        do {
            try encoder.encode(wav: wav, to: temporary)
        } catch {
            return .keptWAV(reason: error.localizedDescription)
        }
        if let problem = problem(withM4A: temporary, comparedTo: wav) {
            return .keptWAV(reason: problem)
        }
        do {
            try files.moveItem(at: temporary, to: m4a)
        } catch {
            return .keptWAV(reason: error.localizedDescription)
        }
        do {
            try files.removeItem(at: wav)
        } catch {
            // Both files exist, which loses nothing.
            return .keptWAV(reason: "the M4A is fine, but the WAV couldn't be deleted: \(error.localizedDescription)")
        }
        return .archived(m4a: m4a)
    }
}

/// Splits a two-track recording into mono files, one per track, for transcription.
enum AudioTracks {

    struct Split {
        /// Nil if the file has no mic track, or the track is silent.
        let mic: URL?
        let system: URL?
        /// Tracks that sound like only steady, quiet noise, by name. They're still
        /// transcribed, so their lines are doubtful (D-56).
        var soundsLikeNoise: [String] = []
    }

    /// Below this peak, a track counts as silent: an unconnected mic writes zeros.
    static let silencePeak: Float = 0.001

    /// Finding from the deep review: Whisper turns steady room noise into invented
    /// speech, in an invented language, labelled as a person. So a track that stays
    /// quiet and steady for a whole part is flagged as doubtful.
    ///
    /// It's flagged, not dropped (D-56). Soft speech over a noise floor measures the
    /// same, and Whisper reads it well, so level alone can't tell them apart, and
    /// dropping real speech is worse than a line of nonsense.
    ///
    /// Levels are measured over 100 ms. Finding from the deep-review re-check: over a
    /// whole second, soft speech varied by under 2x and passed as steady, because each
    /// second averages words and the pauses between them. 100 ms sees those apart.
    ///
    /// These numbers come from invented white noise and `say` speech, not a real room.
    /// The 👤 real call is the first test of them, and they may need changing.
    static let quietLevel: Float = 0.005
    static let steadyRatio: Float = 2
    static let levelWindowFrames = 4_800
    /// Fewer 100 ms windows than this, which is 5 s, can't show whether a track is steady.
    static let fewestWindows = 50

    /// `levels` holds the RMS level of each 100 ms of a track.
    static func isSteadyQuietNoise(levels: [Float]) -> Bool {
        guard levels.count >= fewestWindows, let loudest = levels.max() else { return false }
        let median = levels.sorted()[levels.count / 2]
        return loudest < quietLevel && loudest < median * steadyRatio
    }

    /// Channel 1 is the mic and channel 2 is system audio. A one-channel file is an
    /// older mix, which can't be told apart, so all of it counts as system audio.
    static func split(_ source: URL, into dir: URL) throws -> Split {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        guard channels == 2 else {
            return Split(mic: nil, system: source)
        }
        guard
            let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
            let stereo = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 2, interleaved: false)
        else { throw CocoaError(.fileReadUnknown) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let name = source.deletingPathExtension().lastPathComponent
        let micURL = dir.appendingPathComponent(name + ".mic.wav")
        let systemURL = dir.appendingPathComponent(name + ".system.wav")
        var peaks: [Float] = [0, 0]
        var levels: [[Float]] = [[], []]
        do {
            let outputs = [
                try AVAudioFile(
                    forWriting: micURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
                try AVAudioFile(
                    forWriting: systemURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
            ]
            let reader = try AVAudioFile(
                forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
            let capacity: AVAudioFrameCount = 48_000
            guard let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: capacity),
                let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity)
            else { throw CocoaError(.fileReadUnknown) }
            while reader.framePosition < reader.length {
                try reader.read(into: buffer, frameCount: capacity)
                let frames = Int(buffer.frameLength)
                if frames == 0 { break }
                out.frameLength = buffer.frameLength
                for channel in 0..<2 {
                    let src = buffer.floatChannelData![channel]
                    let dst = out.floatChannelData![0]
                    for f in 0..<frames {
                        dst[f] = src[f]
                        peaks[channel] = max(peaks[channel], abs(src[f]))
                    }
                    // A short window at the end says little, so it isn't counted.
                    var start = 0
                    while start + levelWindowFrames <= frames {
                        var energy: Float = 0
                        for f in start..<(start + levelWindowFrames) { energy += src[f] * src[f] }
                        levels[channel].append((energy / Float(levelWindowFrames)).squareRoot())
                        start += levelWindowFrames
                    }
                    try outputs[channel].write(from: out)
                }
            }
        }
        let noise = levels.map(isSteadyQuietNoise(levels:))
        return Split(
            mic: peaks[0] >= silencePeak ? micURL : nil,
            system: peaks[1] >= silencePeak ? systemURL : nil,
            soundsLikeNoise: (noise[0] && peaks[0] >= silencePeak ? ["mic"] : [])
                + (noise[1] && peaks[1] >= silencePeak ? ["system audio"] : []))
    }
}

/// Only for scripts/e2e.sh: a two-track WAV from two mono files, through the real writer.
enum AudioFixtures {
    /// `--two-track-*` and `--finish-recording` overwrite and delete files by path,
    /// so they do nothing unless a script asks for them on purpose.
    static func scriptFlagsEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["MEETINGCAPTURE_E2E"] == "1"
    }

    static func writeTwoTrack(mic: URL, system: URL, systemDelay: Double, to out: URL) throws {
        let rate = TrackWriter.sampleRate
        let micSamples = try samples(of: mic)
        let delay = [Float](repeating: 0, count: Int(systemDelay * rate))
        let systemSamples = delay + (try samples(of: system))
        let frames = max(micSamples.count, systemSamples.count)
        guard
            let stereo = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)
        else { throw CocoaError(.fileWriteUnknown) }
        let writer = try TrackWriter(outputURL: out, chunkFrameLimit: frames + 1)
        let step = 4_800
        var cursor = 0
        while cursor < frames {
            let count = min(step, frames - cursor)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(count)),
                let dst = buffer.floatChannelData?[0]
            else { throw CocoaError(.fileWriteUnknown) }
            buffer.frameLength = AVAudioFrameCount(count)
            var mono = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let at = cursor + i
                mono[i] = at < micSamples.count ? micSamples[at] : 0
                let sample = at < systemSamples.count ? systemSamples[at] : 0
                dst[2 * i] = sample
                dst[2 * i + 1] = sample
            }
            mono.withUnsafeBufferPointer { writer.pushMic(mono: $0.baseAddress!, frameCount: count) }
            writer.pushSystem(buffer)
            cursor += count
        }
    }

    private static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadUnknown) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadUnknown) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
