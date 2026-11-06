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
        guard abs(original - encoded) <= durationTolerance else {
            return String(format: "the M4A is %.1f s long but the WAV is %.1f s", encoded, original)
        }
        return nil
    }

    static func archive(wav: URL, encoder: AudioEncoding = AACEncoder()) -> Outcome {
        let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
        do {
            try encoder.encode(wav: wav, to: m4a)
        } catch {
            try? FileManager.default.removeItem(at: m4a)
            return .keptWAV(reason: error.localizedDescription)
        }
        if let problem = problem(withM4A: m4a, comparedTo: wav) {
            try? FileManager.default.removeItem(at: m4a)
            return .keptWAV(reason: problem)
        }
        do {
            try FileManager.default.removeItem(at: wav)
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
    }

    /// Below this peak, a track counts as silent: an unconnected mic writes zeros.
    static let silencePeak: Float = 0.001

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
                    try outputs[channel].write(from: out)
                }
            }
        }
        return Split(
            mic: peaks[0] >= silencePeak ? micURL : nil,
            system: peaks[1] >= silencePeak ? systemURL : nil)
    }
}
