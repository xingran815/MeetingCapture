import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// A test with its own temp folder. Audio is short, generated, and goes through the real writer.
class AudioTestCase: XCTestCase {

    var dir: URL!
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    /// True if there's anything at this name, even a symlink pointing nowhere.
    func entryExists(_ name: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url(name).path)) != nil
    }

    @discardableResult
    func touch(_ name: String, contents: Data = Data()) throws -> URL {
        XCTAssertTrue(FileManager.default.createFile(atPath: url(name).path, contents: contents))
        return url(name)
    }

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func saveSidecar(_ base: String, _ value: RecordingSidecar) throws {
        try value.save(to: RecordingSidecar.url(forBase: url(base)))
    }

    func loadSidecar(_ base: String) -> RecordingSidecar? {
        RecordingSidecar.load(at: RecordingSidecar.url(forBase: url(base)))
    }

    /// A finished recording, transcribed `ageDays` ago, listing these files.
    func transcribed(ageDays: Double, files: [String]) -> RecordingSidecar {
        let date = now.addingTimeInterval(-ageDays * 86_400)
        return RecordingSidecar(createdAt: date, state: .processed, transcribedAt: date, audioFiles: files)
    }

    @discardableResult
    func wav(_ name: String, seconds: Double = 1, mic: Bool = false, system: Bool = true) throws -> URL {
        try TestAudio.writeWAV(
            at: url(name), seconds: seconds, mic: mic ? TestAudio.micTone : nil,
            system: system ? TestAudio.systemTone : nil)
        return url(name)
    }
}

enum TestAudio {
    static let rate = Int(TrackWriter.sampleRate)
    static let micTone: (Int) -> Float = { 0.25 * sin(Float($0) * 0.05) }
    static let systemTone: (Int) -> Float = { 0.5 * sin(Float($0) * 0.03) }

    /// Interleaved stereo float32, the shape SCStream delivers. Both sides get the same sample.
    static func stereo(frames: Int, _ sample: (Int) -> Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: TrackWriter.sampleRate, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<frames {
            out[2 * i] = sample(i)
            out[2 * i + 1] = out[2 * i]
        }
        return buffer
    }

    static func pushMic(_ writer: TrackWriter, frames: Int, _ sample: (Int) -> Float) {
        let samples = (0..<frames).map(sample)
        samples.withUnsafeBufferPointer { writer.pushMic(mono: $0.baseAddress!, frameCount: frames) }
    }

    /// A finalized two-track WAV. A nil track stays silent.
    static func writeWAV(
        at url: URL, seconds: Double, mic: ((Int) -> Float)?, system: ((Int) -> Float)?
    ) throws {
        try autoreleasepool {
            let writer = try TrackWriter(outputURL: url)
            let total = Int(seconds * Double(rate))
            var written = 0
            while written < total {
                let frames = min(rate, total - written)
                let start = written
                if let mic { pushMic(writer, frames: frames) { mic(start + $0) } }
                writer.pushSystem(try stereo(frames: frames) { system?(start + $0) ?? 0 })
                written += frames
            }
        }
    }

    /// Both tracks of a file as samples: channel 1, then channel 2.
    static func tracks(of url: URL) throws -> (mic: [Float], system: [Float]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0 else { return ([], []) }
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let count = Int(buffer.frameLength)
        return (
            Array(UnsafeBufferPointer(start: data[0], count: count)),
            Array(UnsafeBufferPointer(start: data[1], count: count))
        )
    }

    static func offsetOfDataChunk(in bytes: Data) throws -> Int {
        try XCTUnwrap(bytes.range(of: Data("data".utf8))).lowerBound
    }

    /// What a hard exit leaves: the audio on disk, and sizes saying there's none.
    static func crash(_ url: URL) throws {
        try setSizes(of: url, data: 0, riff: 0)
    }

    static func setSizes(of url: URL, data: UInt32, riff: UInt32?) throws {
        var bytes = try Data(contentsOf: url)
        let marker = try offsetOfDataChunk(in: bytes)
        bytes.replaceSubrange((marker + 4)..<(marker + 8), with: littleEndian(data))
        if let riff { bytes.replaceSubrange(4..<8, with: littleEndian(riff)) }
        try bytes.write(to: url)
    }

    static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

/// Answers per track, by the split file's name, and remembers what it was given.
final class ScriptedTranscriber: SpeechTranscribing {
    var paths: [String] = []
    var answer: (String) throws -> [Transcriber.Segment]

    init(_ answer: @escaping (String) throws -> [Transcriber.Segment]) {
        self.answer = answer
    }

    /// The same words for every track.
    convenience init(text: String) {
        self.init { _ in [Transcriber.Segment(start: 0.5, end: 1, text: text)] }
    }

    func transcribeSegments(path: String) async throws -> [Transcriber.Segment] {
        paths.append(path)
        return try answer(path)
    }
}

final class ScriptedDetector: SpeakerDetecting {
    var answer: (String) throws -> [SpeakerTurn]

    init(_ answer: @escaping (String) throws -> [SpeakerTurn] = { _ in [SpeakerTurn(start: 0, end: 100, speaker: 7)] })
    {
        self.answer = answer
    }

    func detectTurns(path: String) async throws -> [SpeakerTurn] { try answer(path) }
}

struct FailingEncoder: AudioEncoding {
    func encode(wav: URL, to m4a: URL) throws { throw CocoaError(.fileWriteOutOfSpace) }
}

/// Sets an environment variable for one test. Unset with nil.
func withEnvironment<T>(_ name: String, _ value: String?, _ body: () async throws -> T) async rethrows -> T {
    let before = getenv(name).map { String(cString: $0) }
    if let value { setenv(name, value, 1) } else { unsetenv(name) }
    defer {
        if let before { setenv(name, before, 1) } else { unsetenv(name) }
    }
    return try await body()
}
