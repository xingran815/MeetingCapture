import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// M3.2: the echo is removed from a copy of the mic after the call. All audio is invented
/// (see `EchoLab`): noise bursts through a synthetic room with a 150 ms delay.
final class EchoRemoverTests: AudioTestCase {

    private let rate = Double(EchoLab.rate)

    /// Runs the remover on these two tracks. Returns nil if it found no echo.
    private func clean(mic: [Double], system: [Double]) throws -> (result: EchoRemover.Result, audio: [Double])? {
        try EchoLab.writeMono(mic, to: url("mic.wav"))
        try EchoLab.writeMono(system, to: url("system.wav"))
        guard let result = try EchoRemover.clean(mic: url("mic.wav"), system: url("system.wav"), to: url("out.wav"))
        else {
            XCTAssertFalse(exists("out.wav"), "nothing was found, so nothing should be left behind")
            return nil
        }
        return (result, try EchoLab.read(result.cleaned))
    }

    // MARK: 1. Reduction

    func testFarEndEchoComesDownByAtLeast30dB() throws {
        let scene = EchoScene.standard
        let mic = scene.micEchoOnly
        let (result, out) = try XCTUnwrap(try clean(mic: mic, system: scene.far))
        let reduction = EchoLab.reductionDB(input: mic, output: out, from: 6, to: 23.5)
        print("EchoRemoverTests: far-end echo reduced by \(reduction) dB, lag \(result.lagSeconds * 1000) ms")
        XCTAssertGreaterThanOrEqual(reduction, 30)
        // 150 ms behind: the sign is positive, meaning the mic is behind the system audio.
        XCTAssertEqual(result.lagSeconds, 0.150, accuracy: 0.001)
        XCTAssertEqual(result.driftPPM, 0, accuracy: 0.001, "24 s is too short to show a drift")
    }

    func testAShortDelayIsRemovedToo() throws {
        let far = EchoLab.speech(seconds: 24, seed: 12, rms: 0.1)
        let mic = EchoLab.sum(EchoLab.echo(of: far, delay: 1_440), EchoLab.noise(far.count, seed: 6, rms: 0.0003))
        let (result, out) = try XCTUnwrap(try clean(mic: mic, system: far))
        XCTAssertEqual(result.lagSeconds, 0.030, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(EchoLab.reductionDB(input: mic, output: out, from: 6, to: 23.5), 30)
    }

    /// Found while writing these tests: the last ~50 ms of the file keeps its echo, because the
    /// crossfade weight at the very end drops under the 1e-3 floor that `normalised` divides
    /// by, so the estimate is shrunk there. Small, but it is the end of every recording.
    func testTheLastFramesOfTheFileAreCleanedToo() throws {
        let scene = EchoScene.standard  // far-end speech is loud through 23.7-24 s
        let mic = scene.micEchoOnly
        let (_, out) = try XCTUnwrap(try clean(mic: mic, system: scene.far))
        XCTAssertGreaterThanOrEqual(EchoLab.reductionDB(input: mic, output: out, from: 23.8, to: 24), 25)
        XCTAssertGreaterThanOrEqual(EchoLab.reductionDB(input: mic, output: out, from: 23.95, to: 24), 25)
    }

    /// The known risk from M3's review: with the echo ahead of the reference, a filter that
    /// only looks behind finds nothing. It may stop, but it must never make the mic worse.
    func testAnEchoAheadOfTheReferenceIsLeftAloneOrImproved() throws {
        let far = EchoLab.speech(seconds: 24, seed: 13, rms: 0.1)
        let mic = EchoLab.sum(EchoLab.echo(of: far, delay: 0), EchoLab.noise(far.count, seed: 7, rms: 0.0003))
        let system = EchoLab.shifted(far, by: 960)  // the reference runs 20 ms late
        guard let (_, out) = try clean(mic: mic, system: system) else { return }
        XCTAssertGreaterThanOrEqual(EchoLab.reductionDB(input: mic, output: out, from: 6), -1, "the mic got louder")
    }

    // MARK: 2. The voice stays

    func testTheUsersVoiceAloneIsNotChangedWhileTheFarSideIsSilent() throws {
        let far = EchoLab.speech(seconds: 24, seed: 11, rms: 0.1)
        let talking = EchoLab.only(far, seconds: 0...12)  // the far side stops at 12 s
        let voice = EchoLab.only(EchoLab.speech(seconds: 24, seed: 77, rms: 0.1), seconds: 14...24)
        let mic = EchoLab.sum(
            EchoLab.sum(EchoLab.echo(of: talking), voice), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        let (_, out) = try XCTUnwrap(try clean(mic: mic, system: talking))
        let change = EchoLab.levelChangeDB(input: mic, output: out, seconds: 15...23.5)
        print("EchoRemoverTests: voice alone changed by \(change) dB")
        XCTAssertEqual(change, 0, accuracy: 0.5)
    }

    func testTheUsersVoiceSurvivesDoubleTalk() throws {
        let scene = EchoScene.standard
        let voice = EchoLab.only(EchoLab.speech(seconds: 24, seed: 77, rms: 0.1), seconds: 10...24)
        let mic = EchoLab.sum(scene.micEchoOnly, voice)
        let (_, out) = try XCTUnwrap(try clean(mic: mic, system: scene.far))
        // What is left should be the voice, whatever the echo did.
        let change = EchoLab.levelChangeDB(input: voice, output: out, seconds: 12...23.5)
        print("EchoRemoverTests: voice in double talk changed by \(change) dB")
        XCTAssertEqual(change, 0, accuracy: 3)
        // And the echo before the voice came in still went.
        XCTAssertGreaterThanOrEqual(EchoLab.reductionDB(input: scene.micEchoOnly, output: out, from: 6, to: 10), 30)
    }

    // MARK: 3. The hard requirement

    /// Spec M3.2, "a repeat is not an echo": the user says the far side's exact words, 2 s
    /// or more later, at their own level, while the system is silent. They must survive,
    /// and the label check must not call them echo. Nothing here looks at words.
    func testARepeatOfTheFarSidesWordsIsNotAnEcho() throws {
        let far = EchoLab.speech(seconds: 24, seed: 21, rms: 0.1)
        let said = Array(far[(1 * EchoLab.rate)..<(6 * EchoLab.rate)])  // what the far side says, 1 to 6 s
        let system = EchoLab.only(far, seconds: 1...6)
        // The user repeats it from 8.5 s on, at 0.7 of the level, with no room in between.
        let repeated = EchoLab.adding(
            [Double](repeating: 0, count: far.count), said, at: Int(8.5 * rate), gain: 0.7)
        let mic = EchoLab.sum(
            EchoLab.sum(EchoLab.echo(of: system), repeated), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        let (result, out) = try XCTUnwrap(try clean(mic: mic, system: system))

        let change = EchoLab.levelChangeDB(input: repeated, output: out, seconds: 8.6...13.4)
        print("EchoRemoverTests: repeat changed by \(change) dB")
        XCTAssertEqual(change, 0, accuracy: 0.5, "the repeat was bent")
        // The output still holds the repeat, not just something as loud: it correlates.
        let kept = Array(out[Int(8.5 * rate)..<Int(13.5 * rate)])
        let wanted = Array(repeated[Int(8.5 * rate)..<Int(13.5 * rate)])
        XCTAssertGreaterThan(correlation(kept, wanted), 0.99)

        XCTAssertFalse(result.evidence.looksLikeEcho(start: 8.5, end: 13.5), "a repeat was labelled echo")
        // The same check does call the real echo, 1 to 6.3 s, echo.
        XCTAssertTrue(result.evidence.looksLikeEcho(start: 1.2, end: 6.2), "the echo itself wasn't recognised")
    }

    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0
        var aa = 0.0
        var bb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            aa += a[i] * a[i]
            bb += b[i] * b[i]
        }
        return dot / max((aa * bb).squareRoot(), 1e-30)
    }

    // MARK: 4. No echo

    func testHeadphonesGiveNoEchoAndNothingIsWritten() throws {
        let far = EchoLab.speech(seconds: 24, seed: 11, rms: 0.1)
        let voice = EchoLab.speech(seconds: 24, seed: 77, rms: 0.1)
        let mic = EchoLab.sum(voice, EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        XCTAssertNil(try clean(mic: mic, system: far))
    }

    func testASilentSystemTrackGivesNoEcho() throws {
        let voice = EchoLab.speech(seconds: 10, seed: 77, rms: 0.1)
        XCTAssertNil(try clean(mic: voice, system: [Double](repeating: 0, count: voice.count)))
    }

    func testEmptyTracksGiveNoEcho() throws {
        XCTAssertNil(try clean(mic: [], system: []))
    }

    // MARK: 5. Clock drift

    /// 180 s of audio with the mic's clock 8 ppm fast. The lag grows about 61 samples
    /// over the recording, and the track of lags gives that back as a drift.
    func testEightPPMOfClockDriftIsMeasuredFromAudio() throws {
        let far = EchoLab.speech(seconds: 180, seed: 31, rms: 0.1)
        let delayed = EchoLab.shifted(far, by: EchoLab.delay)
        let mic = EchoLab.sum(
            EchoLab.warped(delayed, ppm: 8), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        try EchoLab.writeMono(mic, to: url("mic.wav"))
        try EchoLab.writeMono(far, to: url("system.wav"))
        let micReader = try MonoReader(url("mic.wav"))
        let systemReader = try MonoReader(url("system.wav"))
        let track = try EchoRemover.lagTrack(mic: micReader, system: systemReader, frames: far.count)
        XCTAssertGreaterThanOrEqual(track.count, 6)
        XCTAssertEqual(try XCTUnwrap(track.first).lag, EchoLab.delay, accuracy: 6)
        XCTAssertEqual(try XCTUnwrap(track.last).lag - EchoLab.delay, 61, accuracy: 12)
        let ppm = EchoRemover.driftPPM(track)
        print("EchoRemoverTests: measured drift \(ppm) ppm")
        XCTAssertEqual(ppm, 8, accuracy: 2)
    }

    func testDriftPPMOnInventedLagPoints() {
        let points = (0..<8).map { i -> EchoRemover.LagPoint in
            let t = 10.0 + 30 * Double(i)
            return EchoRemover.LagPoint(seconds: t, lag: 7_200 + Int((0.384 * t).rounded()))
        }
        XCTAssertEqual(EchoRemover.driftPPM(points), 8, accuracy: 0.5)

        // The other way round.
        let slow = points.map { EchoRemover.LagPoint(seconds: $0.seconds, lag: 14_400 - $0.lag) }
        XCTAssertEqual(EchoRemover.driftPPM(slow), -8, accuracy: 0.5)

        // A flat lag has no drift.
        let flat = points.map { EchoRemover.LagPoint(seconds: $0.seconds, lag: 7_200) }
        XCTAssertEqual(EchoRemover.driftPPM(flat), 0, accuracy: 0.01)
    }

    func testDriftPPMCopesWithOutliers() {
        var points = (0..<10).map { i -> EchoRemover.LagPoint in
            let t = 10.0 + 30 * Double(i)
            return EchoRemover.LagPoint(seconds: t, lag: 7_200 + Int((0.384 * t).rounded()))
        }
        // A far-off lag (another peak won), a lag below the real one, and one that's only
        // a little off, which the 20 ms gate lets through.
        points[2] = EchoRemover.LagPoint(seconds: points[2].seconds, lag: 7_200 + 12_000)
        points[5] = EchoRemover.LagPoint(seconds: points[5].seconds, lag: 400)
        points[7] = EchoRemover.LagPoint(seconds: points[7].seconds, lag: points[7].lag + 700)
        XCTAssertEqual(EchoRemover.driftPPM(points), 8, accuracy: 1.5)
    }

    func testShortTracksHaveNoDrift() {
        let few = (0..<5).map { EchoRemover.LagPoint(seconds: 30 * Double($0), lag: 7_200 + 12 * $0) }
        XCTAssertEqual(EchoRemover.driftPPM(few), 0)
        let close = (0..<8).map { EchoRemover.LagPoint(seconds: 5 * Double($0), lag: 7_200 + 12 * $0) }
        XCTAssertEqual(EchoRemover.driftPPM(close), 0, "35 s can't show a drift")
        XCTAssertEqual(EchoRemover.driftPPM([]), 0)
        XCTAssertNil(EchoRemover.medianLag([]))
    }

    // MARK: 7. Length

    func testOutputHasExactlyAsManyFramesAsTheInput() throws {
        // Not multiples of the 512 hop, the 2 s fit hop, or a power of two. The last two are
        // shorter than the 8 s fit window, and the first is shorter than the 20 s lag window.
        for frames in [3 * EchoLab.rate + 777, 9 * EchoLab.rate + 511, 12 * EchoLab.rate + 1, 5 * EchoLab.rate + 100] {
            let far = EchoLab.speech(frames: frames, seed: UInt64(frames), rms: 0.1)
            let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(frames, seed: 5, rms: 0.0003))
            let (_, out) = try XCTUnwrap(try clean(mic: mic, system: far), "\(frames) frames")
            XCTAssertEqual(out.count, frames)
            try FileManager.default.removeItem(at: url("out.wav"))
        }
    }

    func testFilesShorterThanAWindowOrTheFFTNeverGrowOrCrash() throws {
        for frames in [1, 100, 511, 513, 3_000, 20_000, 48_000 + 3] {
            let far = EchoLab.speech(frames: frames, seed: 4, rms: 0.1)
            let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(frames, seed: 5, rms: 0.0003))
            if let (_, out) = try clean(mic: mic, system: far) {
                XCTAssertEqual(out.count, frames)
                try FileManager.default.removeItem(at: url("out.wav"))
            }
        }
    }

    // MARK: Failure

    func testAWrongRateTrackIsAnError() throws {
        let x = EchoLab.speech(seconds: 3, seed: 1, rms: 0.1)
        try EchoLab.writeMono(x, to: url("mic.wav"), rate: 44_100)
        try EchoLab.writeMono(x, to: url("system.wav"))
        XCTAssertThrowsError(try EchoRemover.clean(mic: url("mic.wav"), system: url("system.wav"), to: url("o.wav")))
        XCTAssertThrowsError(try EchoRemover.clean(mic: url("system.wav"), system: url("mic.wav"), to: url("o.wav")))
        XCTAssertThrowsError(
            try EchoRemover.clean(mic: url("missing.wav"), system: url("system.wav"), to: url("o.wav")))
    }

    func testAStereoTrackIsAnError() throws {
        try wav("two.wav", seconds: 3, mic: true)
        try EchoLab.writeMono(EchoLab.speech(seconds: 3, seed: 1, rms: 0.1), to: url("system.wav"))
        XCTAssertThrowsError(try EchoRemover.clean(mic: url("two.wav"), system: url("system.wav"), to: url("o.wav")))
    }
}
