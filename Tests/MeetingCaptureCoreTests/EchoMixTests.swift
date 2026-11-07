import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// User asked: "_clean.m4a is just like the original recording with echo canceled" (M3.2).
/// So the `_clean` file has the recording's layout: channel 1 the cleaned mic, channel 2 the
/// system track untouched, frame for frame in step. Invented audio only, no model.
final class EchoMixTests: AudioTestCase {

    private let rate = EchoRemover.sampleRate
    private let int16Step = 1.0 / 32_768 * 1.5

    private func mix(mic: [Double], system: [Double]) throws -> URL {
        try EchoLab.writeMono(mic, to: url("mic.wav"))
        try EchoLab.writeMono(system, to: url("sys.wav"))
        try EchoRemover.mix(mic: url("mic.wav"), system: url("sys.wav"), to: url("out.wav"))
        return url("out.wav")
    }

    private func maxDiff(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    func testUserAskedCleanIsTwoChannelsAt48kWithTheLongerInputsLength() throws {
        let mic = EchoLab.noise(rate * 3, seed: 1, rms: 0.1)
        let system = EchoLab.noise(rate * 3 + 777, seed: 2, rms: 0.1)
        let out = try mix(mic: mic, system: system)
        let file = try AVAudioFile(forReading: out)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.sampleRate, Double(rate))
        XCTAssertEqual(Int(file.length), system.count)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
    }

    func testChannelTwoIsTheSystemTrackAndChannelOneTheMicSampleForSample() throws {
        // 12 s crosses the 10 s chunk the mixer works in.
        let mic = EchoLab.noise(rate * 12, seed: 3, rms: 0.1)
        let system = EchoLab.noise(rate * 12, seed: 4, rms: 0.1)
        let out = try mix(mic: mic, system: system)
        let c1 = try EchoLab.read(out, channel: 0)
        let c2 = try EchoLab.read(out, channel: 1)
        XCTAssertEqual(c1.count, mic.count)
        XCTAssertEqual(c2.count, system.count)
        XCTAssertLessThan(maxDiff(c1, mic), int16Step, "channel 1 is the mic")
        XCTAssertLessThan(maxDiff(c2, system), int16Step, "channel 2 is the system track, unchanged")
        XCTAssertGreaterThan(maxDiff(mic, system), 0.05, "the two inputs differ, so a swap would show")
    }

    func testThereIsNoLagBetweenInputAndOutputChannels() throws {
        let n = rate * 11
        let at = 10 * rate + 123  // past the first chunk boundary
        let early = 4_321
        var mic = [Double](repeating: 0, count: n)
        var system = [Double](repeating: 0, count: n)
        mic[early] = 0.5
        mic[at] = 0.25
        system[early + 500] = -0.5
        system[at + 1] = -0.25
        let out = try mix(mic: mic, system: system)
        let c1 = try EchoLab.read(out, channel: 0)
        let c2 = try EchoLab.read(out, channel: 1)
        func peaks(_ x: [Double]) -> [Int] { x.indices.filter { abs(x[$0]) > 0.1 } }
        XCTAssertEqual(peaks(c1), [early, at])
        XCTAssertEqual(peaks(c2), [early + 500, at + 1])
        XCTAssertGreaterThan(c1[early], 0)
        XCTAssertLessThan(c2[early + 500], 0)
    }

    func testAShorterMicIsPaddedWithZerosAndAShorterSystemTooWithoutShiftingAnything() throws {
        let long = EchoLab.noise(rate * 2, seed: 5, rms: 0.1)
        let short = Array(EchoLab.noise(rate, seed: 6, rms: 0.1))

        let a = try mix(mic: short, system: long)
        let aMic = try EchoLab.read(a, channel: 0)
        XCTAssertEqual(aMic.count, long.count)
        XCTAssertLessThan(maxDiff(Array(aMic[0..<short.count]), short), int16Step)
        XCTAssertEqual(aMic[short.count...].map(abs).max() ?? 1, 0, accuracy: 1e-9, "mic is padded with zeros")
        XCTAssertLessThan(maxDiff(try EchoLab.read(a, channel: 1), long), int16Step)

        try FileManager.default.removeItem(at: url("out.wav"))
        let b = try mix(mic: long, system: short)
        let bSys = try EchoLab.read(b, channel: 1)
        XCTAssertEqual(bSys.count, long.count)
        XCTAssertLessThan(maxDiff(Array(bSys[0..<short.count]), short), int16Step)
        XCTAssertEqual(bSys[short.count...].map(abs).max() ?? 1, 0, accuracy: 1e-9, "system is padded with zeros")
        XCTAssertLessThan(maxDiff(try EchoLab.read(b, channel: 0), long), int16Step)
    }

    // MARK: Through the pipeline

    /// 12 s: the far side talks for 6 s and the room echoes it, then the user speaks.
    func testUserAskedPipelineCleanFileHasBothChannelsWithTheSystemUntouchedAndLessEchoOnTheMic() async throws {
        let far = EchoLab.speech(seconds: 12, seed: 11, rms: 0.1)
        let system = EchoLab.only(far, seconds: 0...6)
        let voice = EchoLab.only(EchoLab.speech(seconds: 12, seed: 77, rms: 0.1), seconds: 8...12)
        let mic = EchoLab.sum(
            EchoLab.sum(EchoLab.echo(of: system), voice), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        try EchoLab.writeTwoTrack(mic: mic, system: system, to: url("m.wav"))

        let transcriber = ScriptedTranscriber { _ in [Transcriber.Segment(start: 9, end: 11, text: "words")] }
        var pipeline = RecordingPipeline(transcriber: transcriber, detector: nil)
        pipeline.removeEcho = true
        let result = try await pipeline.transcribe(parts: [url("m.wav")], keepingCleanedAudio: true)

        XCTAssertEqual(result.cleanedAudio, [url("m_clean.wav")])
        let clean = try AVAudioFile(forReading: url("m_clean.wav"))
        XCTAssertEqual(clean.fileFormat.channelCount, 2, "same layout as the raw recording")
        XCTAssertEqual(clean.fileFormat.sampleRate, 48_000)

        let rawMic = try EchoLab.read(url("m.wav"), channel: 0)
        let rawSystem = try EchoLab.read(url("m.wav"), channel: 1)
        let cleanMic = try EchoLab.read(url("m_clean.wav"), channel: 0)
        let cleanSystem = try EchoLab.read(url("m_clean.wav"), channel: 1)
        XCTAssertEqual(cleanSystem.count, cleanMic.count)
        XCTAssertLessThanOrEqual(abs(cleanMic.count - rawMic.count), 1)
        let n = min(cleanSystem.count, rawSystem.count)
        XCTAssertLessThan(maxDiff(Array(cleanSystem[0..<n]), Array(rawSystem[0..<n])), int16Step)
        XCTAssertGreaterThan(EchoRemover.meanPower(cleanSystem), 0.001, "the far side is still there")
        XCTAssertGreaterThanOrEqual(
            EchoLab.reductionDB(input: rawMic, output: cleanMic, from: 2, to: 5), 15,
            "channel 1 has less echo than the raw mic")
    }
}
