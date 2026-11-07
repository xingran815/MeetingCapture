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
    /// From the M3.2 deep review, finding 10: the old version returned on nil and proved
    /// nothing. Each outcome now asserts something real.
    func testAnEchoAheadOfTheReferenceIsLeftAloneOrImproved() throws {
        let far = EchoLab.speech(seconds: 24, seed: 13, rms: 0.1)
        let mic = EchoLab.sum(EchoLab.echo(of: far, delay: 0), EchoLab.noise(far.count, seed: 7, rms: 0.0003))
        let system = EchoLab.shifted(far, by: 960)  // the reference runs 20 ms late
        guard let (result, out) = try clean(mic: mic, system: system) else {
            // Nothing found: the lag search only looks 2 ms or more behind the reference, so
            // it must not have invented a lag, and no file was left (checked by `clean`).
            let micReader = try MonoReader(url("mic.wav"))
            let systemReader = try MonoReader(url("system.wav"))
            let track = try EchoRemover.lagTrack(mic: micReader, system: systemReader, frames: far.count)
            print("EchoRemoverTests: echo ahead of the reference: nothing found")
            XCTAssertEqual(track.count, 0, "no echo was reported, yet the lag search found \(track)")
            return
        }
        // Found: it must be real (a lag the search allows), the length is kept, the mic
        // never got louder, and no frame of the output is wilder than the mic's own peak.
        XCTAssertGreaterThanOrEqual(result.lagSeconds, 0.002)
        XCTAssertEqual(out.count, mic.count)
        XCTAssertGreaterThanOrEqual(EchoLab.reductionDB(input: mic, output: out, from: 6), -1, "the mic got louder")
        XCTAssertLessThanOrEqual(out.map(abs).max() ?? 0, 1.5 * (mic.map(abs).max() ?? 0))
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
        // From the M3.2 deep review, finding 2: a level can be matched by leftover echo, so
        // the output must also point the same way as the voice (projection on it).
        let kept = Array(out[(12 * EchoLab.rate)..<Int(23.5 * rate)])
        let wanted = Array(voice[(12 * EchoLab.rate)..<Int(23.5 * rate)])
        let projection = correlation(kept, wanted)
        print("EchoRemoverTests: voice in double talk, projection \(projection)")
        XCTAssertGreaterThan(projection, 0.9)
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

    /// From the M3.2 review, finding 2. A soft speaker, talking over the far side, has a big
    /// drop and a level near the room, so level alone would call the line echo. The ceiling
    /// follows the same speaker's voice while the far side is silent.
    func testSoftSpeechOverAnEchoIsNotReportedAsEchoWhenTheSameVoiceIsHeardAlone() throws {
        let scene = EchoScene.standard
        let system = EchoLab.only(scene.far, seconds: 0...12)
        let soft = EchoLab.speech(seconds: 24, seed: 77, rms: 0.0007)  // barely over the room
        let voice = EchoLab.sum(EchoLab.only(soft, seconds: 3...10), EchoLab.only(soft, seconds: 13...23))
        let mic = EchoLab.sum(EchoLab.sum(EchoLab.echo(of: system), voice), scene.noise)
        let (result, _) = try XCTUnwrap(try clean(mic: mic, system: system))

        let e = result.evidence
        print("EchoRemoverTests: soft voice \(e.voiceDB ?? .nan) dB, room \(e.roomDB) dB")
        let voiceDB = try XCTUnwrap(e.voiceDB, "the soft voice alone wasn't measured")
        XCTAssertLessThan(voiceDB - e.roomDB, 25, "the test voice isn't soft")
        XCTAssertLessThan(e.ceilingAboveRoom, EchoEvidence.echoCeilingAboveRoom)
        XCTAssertFalse(e.looksLikeEcho(start: 3.2, end: 9.8), "soft speech over an echo was called echo")
        XCTAssertFalse(e.looksLikeEcho(start: 13.2, end: 22.8), "the same soft speech, alone")
        // The control: without the voice, the old 15 dB ceiling would have dropped the line.
        var withoutVoice = e
        withoutVoice.voiceDB = nil
        XCTAssertTrue(withoutVoice.looksLikeEcho(start: 3.2, end: 9.8), "the test doesn't show the problem")
        // The echo with no one speaking is still found.
        XCTAssertTrue(e.looksLikeEcho(start: 0.5, end: 2.5) || e.looksLikeEcho(start: 10.2, end: 11.8))
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
        // From the M3.2 re-check: 3 s of speech has under 2 s of far side talking, which is now
        // no fit and nil (see the very-short-files test), so the shortest here is 6 s.
        for frames in [6 * EchoLab.rate + 777, 9 * EchoLab.rate + 511, 12 * EchoLab.rate + 1, 5 * EchoLab.rate + 100] {
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

    // MARK: From the M3.2 deep review

    /// From the M3.2 deep review, finding 1. The warp pivots at the file's start, so the
    /// reference has to be shifted by the lag there, not the median. 300 ppm over 220 s puts
    /// the middle 1584 samples from the start, past the 1440 (30 ms lead) the old code
    /// could absorb, so a shift from the median missed a fast mic clock's echo. (Above about
    /// 300 ppm the lag search itself loses the peak in a 20 s window, so this is as large as
    /// a measurable drift gets.) Both signs must clean, and the first seconds are where a
    /// shift from the median fails: the echo is then ahead of the reference.
    func testACleanedPartKeepsItsReductionWithAFastMicClock() throws {
        for ppm in [300.0, -300.0] {
            let (result, mic, out) = try autoreleasepool { () -> (EchoRemover.Result, [Double], [Double]) in
                let far = EchoLab.speech(seconds: 220, seed: 51, rms: 0.1)
                // Padded, because a slow clock reads past the end of the source.
                let delayed = EchoLab.shifted(far, by: EchoLab.delay) + [Double](repeating: 0, count: 8_000)
                let mic = EchoLab.sum(
                    Array(EchoLab.warped(delayed, ppm: ppm).prefix(far.count)),
                    EchoLab.noise(far.count, seed: 5, rms: 0.0003))
                let (result, out) = try XCTUnwrap(try clean(mic: mic, system: far), "\(ppm) ppm")
                return (result, mic, out)
            }
            print("EchoRemoverTests: \(ppm) ppm measured as \(result.driftPPM)")
            XCTAssertEqual(result.driftPPM, ppm, accuracy: 25, "\(ppm) ppm")
            for slice in [(2.0, 8.0), (40.0, 70.0), (110.0, 140.0), (170.0, 215.0)] {
                let reduction = EchoLab.reductionDB(input: mic, output: out, from: slice.0, to: slice.1)
                print("EchoRemoverTests: \(ppm) ppm, \(slice): \(reduction) dB")
                XCTAssertGreaterThanOrEqual(reduction, 15, "\(ppm) ppm, \(slice)")
            }
            XCTAssertFalse(result.lagMoved, "a steady drift is not a moved lag")
            try FileManager.default.removeItem(at: url("out.wav"))
        }
    }

    func testLagAtFileStartFollowsTheLineBackToTheStart() {
        // Lag 7000 at the start, growing 19.2 samples a second (400 ppm).
        let points = (0..<8).map { i -> EchoRemover.LagPoint in
            let t = 10.0 + 20 * Double(i)
            return EchoRemover.LagPoint(seconds: t, lag: 7_000 + Int((19.2 * t).rounded()))
        }
        XCTAssertEqual(EchoRemover.lagAtFileStart(points, ppm: 400), 7_000, accuracy: 2)
        // The median lag is what the old code used, and it is far from the start.
        XCTAssertGreaterThan(try XCTUnwrap(EchoRemover.medianLag(points)) - 7_000, 1_000)
        // One false peak doesn't move it.
        var stray = points
        stray[3] = EchoRemover.LagPoint(seconds: stray[3].seconds, lag: 15_000)
        XCTAssertEqual(EchoRemover.lagAtFileStart(stray, ppm: 400), 7_000, accuracy: 2)
        // A slow clock: the lag falls, so the start is above every point.
        let slow = points.map { EchoRemover.LagPoint(seconds: $0.seconds, lag: 14_000 - $0.lag) }
        XCTAssertEqual(EchoRemover.lagAtFileStart(slow, ppm: -400), 7_000, accuracy: 2)
        // Without drift it's the lag itself, and nothing at all gives zero.
        let flat = points.map { EchoRemover.LagPoint(seconds: $0.seconds, lag: 7_200) }
        XCTAssertEqual(EchoRemover.lagAtFileStart(flat, ppm: 0), 7_200)
        XCTAssertEqual(EchoRemover.lagAtFileStart([], ppm: 0), 0)
    }

    /// Finding 2. A short interjection by the far side lets a window through the old
    /// power gate. A fit on 0.4 s of reference and a voice that fills the window can
    /// reproduce the voice and subtract it. The filter fitted during the long talk must
    /// be reused instead.
    func testAShortFarSideInterjectionDoesNotTakeTheVoiceWithIt() throws {
        let seconds = 80.0
        let blips = [40.0, 50.0, 60.0, 70.0]
        let farSpeech = EchoLab.speech(seconds: seconds, seed: 61, rms: 0.1)
        var far = EchoLab.only(farSpeech, seconds: 0...30)
        for t in blips { far = EchoLab.adding(far, Array(farSpeech[0..<Int(0.4 * rate)]), at: Int(t * rate)) }
        // A voice with no gaps in it, so there is always something to steal.
        let voice = EchoLab.scaled(EchoLab.lowpass(EchoLab.noise(far.count, seed: 77, rms: 1)), toRMS: 0.1)
        let echo = EchoLab.echo(of: far)
        let mic = EchoLab.sum(EchoLab.sum(echo, voice), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        let (_, out) = try XCTUnwrap(try clean(mic: mic, system: far))

        for t in blips {
            // The echo of a blip arrives 150 ms late and lasts 0.4 s.
            let a = Int((t + 0.2) * rate)
            let b = Int((t + 0.55) * rate)
            let projection = correlation(Array(out[a..<b]), Array(voice[a..<b]))
            let rawProjection = correlation(Array(mic[a..<b]), Array(voice[a..<b]))
            print("EchoRemoverTests: blip at \(t): projection \(projection), uncleaned \(rawProjection)")
            XCTAssertGreaterThanOrEqual(projection, 0.8, "the voice was taken with the blip at \(t) s")
            // The echo is reduced too: what is left beside the voice is under the echo. The
            // blip is as loud as the voice here, and the measure also counts any bending of the
            // voice, so it reads about 8 dB (the uncleaned mic would read 0).
            let left = zip(out[a..<b], voice[a..<b]).map { $0 - $1 }
            let before = EchoRemover.meanPower(Array(echo[a..<b]))
            XCTAssertGreaterThanOrEqual(
                EchoLab.db(before / max(EchoRemover.meanPower(left), 1e-30)), 6, "echo left at \(t) s")
        }
        // The long talk before was cleaned as usual, and the voice survived there too.
        XCTAssertGreaterThanOrEqual(
            correlation(
                Array(out[(10 * EchoLab.rate)..<(30 * EchoLab.rate)]),
                Array(voice[(10 * EchoLab.rate)..<(30 * EchoLab.rate)])),
            0.9)
    }

    func testActiveSamplesCountsOnlyFramesWithTheFarSideTalking() {
        let frame = EchoLab.rate / 100
        XCTAssertEqual(EchoRemover.activeSamples([]), 0)
        XCTAssertEqual(EchoRemover.activeSamples([Double](repeating: 0, count: 5 * EchoLab.rate)), 0)
        XCTAssertEqual(EchoRemover.activeSamples([Double](repeating: 0.1, count: frame - 1)), 0, "under one frame")
        // 0.4 s of loud, frame-aligned, inside 2 s of silence.
        var x = [Double](repeating: 0, count: 2 * EchoLab.rate)
        for i in (100 * frame)..<(140 * frame) { x[i] = 0.1 }
        XCTAssertEqual(EchoRemover.activeSamples(x), 40 * frame)
        XCTAssertLessThan(EchoRemover.activeSamples(x), Int(EchoRemover.minimumActiveSeconds * rate))
        // Room-noise level (RMS 0.0003) isn't the far side talking: the gate is RMS 0.001.
        XCTAssertEqual(EchoRemover.activeSamples([Double](repeating: 0.0003, count: EchoLab.rate)), 0)
        XCTAssertEqual(EchoRemover.activeSamples([Double](repeating: 0.002, count: EchoLab.rate)), EchoLab.rate)
        // Loud for 2 s clears the minimum.
        XCTAssertGreaterThanOrEqual(
            EchoRemover.activeSamples([Double](repeating: 0.1, count: 2 * EchoLab.rate)),
            Int(EchoRemover.minimumActiveSeconds * rate))
    }

    /// Finding 3. Windows used to start every 30 s and had to fit whole, so a far side that
    /// only talked from 21 s of a 49 s recording fell between the two. Windows now overlap
    /// and the last ends at the file's end.
    func testAFarSideOnlyBetweenScanWindowsIsStillCleaned() throws {
        let far = EchoLab.only(EchoLab.speech(seconds: 49, seed: 71, rms: 0.1), seconds: 21...48)
        let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        let (result, out) = try XCTUnwrap(try clean(mic: mic, system: far))
        XCTAssertEqual(result.lagSeconds, 0.150, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(EchoLab.reductionDB(input: mic, output: out, from: 26, to: 47.5), 25)
        XCTAssertEqual(out.count, mic.count)
    }

    /// Finding 4, the unit side.
    func testLagMovedOnInventedLagPoints() {
        func point(_ t: Double, _ lag: Int) -> EchoRemover.LagPoint { .init(seconds: t, lag: lag) }
        let times = (0..<8).map { 10.0 + 15 * Double($0) }
        // A steady lag.
        XCTAssertFalse(EchoRemover.lagMoved(times.map { point($0, 7_200) }, ppm: 0))
        // A lag that drifts at the measured rate follows the line, so it didn't move.
        XCTAssertFalse(EchoRemover.lagMoved(times.map { point($0, 7_000 + Int((19.2 * $0).rounded())) }, ppm: 400))
        // One stray point can be a false peak.
        var stray = times.map { point($0, 7_200) }
        stray[4] = point(stray[4].seconds, 12_000)
        XCTAssertFalse(EchoRemover.lagMoved(stray, ppm: 0))
        // A step of 62 ms half way through is a move.
        XCTAssertTrue(EchoRemover.lagMoved(times.map { point($0, $0 < 60 ? 7_200 : 10_200) }, ppm: 0))
        // Two points off the line is already a move.
        var two = times.map { point($0, 7_200) }
        two[1] = point(two[1].seconds, 9_000)
        two[6] = point(two[6].seconds, 5_000)
        XCTAssertTrue(EchoRemover.lagMoved(two, ppm: 0))
        // Under 20 ms of wander isn't one.
        XCTAssertFalse(EchoRemover.lagMoved(times.map { point($0, 7_200 + ($0 < 60 ? 0 : 800)) }, ppm: 0))
        XCTAssertFalse(EchoRemover.lagMoved([], ppm: 0))
    }

    /// Finding 4: a delay that jumps mid-part is reported, and a steady one isn't.
    func testAStepInTheDelayMidPartMakesTheRemoverReportALagMove() throws {
        let far = EchoLab.speech(seconds: 60, seed: 81, rms: 0.1)
        let tail = EchoLab.convolve(far, EchoLab.tail(seed: 99))
        let echo = EchoLab.sum(
            EchoLab.only(EchoLab.shifted(tail, by: 7_200), seconds: 0...30),
            EchoLab.only(EchoLab.shifted(tail, by: 10_200), seconds: 30...60))
        let mic = EchoLab.sum(echo, EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        let (result, _) = try XCTUnwrap(try clean(mic: mic, system: far))
        XCTAssertTrue(result.lagMoved, "a 62 ms jump went unreported")
    }

    // MARK: Echo evidence, finding 7

    /// From the M3.2 deep review, finding 7. A line's level is the mean of power over its
    /// loudest fifth, so 1.5 s of real words in a 30 s line, with the rest at the room, is
    /// kept. The old mean of dB averaged it down into the room and left the words out.
    func testAShortWordInALongSegmentIsNotLeftOut() {
        let frames = 3_000  // 30 s
        let room: Float = -60
        let micDB = [Float](repeating: 0, count: frames)  // the echo took the mic up, then it was removed
        var withWord = [Float](repeating: room, count: frames)
        for i in 1_000..<1_150 { withWord[i] = room + 30 }  // 1.5 s, 30 dB over the room
        let kept = EchoEvidence(micDB: micDB, cleanDB: withWord, roomDB: room)
        XCTAssertFalse(kept.looksLikeEcho(start: 0, end: 29.9), "a short real word was dropped with its line")
        // The same word with a drop under the minimum isn't judged either.
        // A line that is really all low stays left out.
        let allLow = EchoEvidence(micDB: micDB, cleanDB: [Float](repeating: room + 2, count: frames), roomDB: room)
        XCTAssertTrue(allLow.looksLikeEcho(start: 0, end: 29.9))
        // And a word only 10 dB over the room, 1.5 s long, still averages under the ceiling.
        var faint = [Float](repeating: room, count: frames)
        for i in 1_000..<1_150 { faint[i] = room + 10 }
        XCTAssertTrue(EchoEvidence(micDB: micDB, cleanDB: faint, roomDB: room).looksLikeEcho(start: 0, end: 29.9))
    }

    // MARK: From the M3.2 re-check

    /// 1 s of far side every 10 s from 5 s to 55 s, then continuous speech from 60 s to 100 s.
    private func earlyBurstsThenTalk() -> (far: [Double], echo: [Double]) {
        let speech = EchoLab.speech(seconds: 100, seed: 91, rms: 0.1)
        var far = EchoLab.only(speech, seconds: 60...100)
        for t in stride(from: 5.0, to: 56, by: 10.0) {
            far = EchoLab.sum(far, EchoLab.only(speech, seconds: t...(t + 1)))
        }
        return (far, EchoLab.echo(of: far))
    }

    /// From the M3.2 re-check: a far side that never talks 2 s inside one fit window has no
    /// fit, and the output would only be the raw mic. So the remover says "nothing" and
    /// leaves no file (the helper checks).
    func testFarSideTooSparseForAFitSaysSoAndListsNoClean() throws {
        let speech = EchoLab.speech(seconds: 60, seed: 92, rms: 0.1)
        var far = [Double](repeating: 0, count: speech.count)
        for t in stride(from: 5.0, to: 60, by: 10.0) {
            far = EchoLab.sum(far, EchoLab.only(speech, seconds: t...(t + 1)))
        }
        let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        XCTAssertNil(try clean(mic: mic, system: far))
        XCTAssertFalse(exists("out.wav"))
    }

    /// From the M3.2 re-check: what comes before the first window that can be fitted used to
    /// get no estimate at all. Now the first filter also cleans it.
    func testEarlyBackchannelBeforeFirstFitIsRemoved() throws {
        let (far, echo) = earlyBurstsThenTalk()
        let mic = EchoLab.sum(echo, EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        let (_, out) = try XCTUnwrap(try clean(mic: mic, system: far))
        let early = EchoLab.reductionDB(input: mic, output: out, from: 4, to: 56)
        print("EchoRemoverTests: early bursts' echo reduced by \(early) dB")
        XCTAssertGreaterThanOrEqual(early, 10)
        XCTAssertEqual(out.count, mic.count)
    }

    /// From the M3.2 re-check: the echo before the first fit was counted as the user "alone"
    /// (no estimate there), which raised `voiceDB` to the echo's level and the line ceiling
    /// with it. A soft line between the bursts must set the level instead.
    func testEchoBeforeFirstFitDoesNotRaiseVoiceLevel() throws {
        let (far, echo) = earlyBurstsThenTalk()
        let soft = EchoLab.only(EchoLab.speech(seconds: 100, seed: 77, rms: 0.003), seconds: 17...23)
        let mic = EchoLab.sum(EchoLab.sum(echo, soft), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        let (result, _) = try XCTUnwrap(try clean(mic: mic, system: far))

        let e = result.evidence
        let voiceDB = try XCTUnwrap(e.voiceDB, "the soft line alone wasn't measured")
        // The user's own loudest fifth, in the same units as `voiceDB`.
        let frames = EchoLab.framePower(soft).enumerated().filter { $0.offset >= 1_700 && $0.offset < 2_300 }
        let loud = frames.map { Float(EchoLab.db($0.element)) }.sorted().suffix(frames.count / 5)
        let wanted = loud.reduce(0, +) / Float(loud.count)
        let echoDB = Float(EchoLab.db(EchoRemover.meanPower(Array(echo[(5 * EchoLab.rate)..<(6 * EchoLab.rate)]))))
        print("EchoRemoverTests: voiceDB \(voiceDB), user \(wanted), echo \(echoDB), room \(e.roomDB)")
        XCTAssertLessThan(voiceDB, echoDB - 15, "the early echo was taken for the user's voice")
        XCTAssertEqual(voiceDB, wanted, accuracy: 6)
        XCTAssertFalse(e.looksLikeEcho(start: 17.2, end: 22.8), "the soft line was reported as echo")
        // The early echo itself is still recognised as echo.
        XCTAssertTrue(e.looksLikeEcho(start: 5.2, end: 6.0))
    }

    /// From the M3.2 re-check: dropping a near-duplicate window left far side unseen. Whatever the
    /// length, the windows start at 0, each starts no later than the previous one ends, and the last
    /// ends at the file's end.
    func testLagWindowsLeaveNoAudioUnseen() throws {
        let window = 20.0
        for seconds in [5.0, 19.99, 20.0, 20.01, 21, 25, 27.4, 35, 41, 42, 57] {
            let frames = Int(seconds * rate)
            let far = EchoLab.speech(frames: frames, seed: 93, rms: 0.1)
            let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(frames, seed: 5, rms: 0.0003))
            try EchoLab.writeMono(mic, to: url("mic.wav"))
            try EchoLab.writeMono(far, to: url("system.wav"))
            let track = try EchoRemover.lagTrack(
                mic: try MonoReader(url("mic.wav")), system: try MonoReader(url("system.wav")), frames: frames)
            let total = Double(frames) / rate
            XCTAssertFalse(track.isEmpty, "\(seconds) s")
            // Centre = start + half the window; a window cut short by the file's end is shorter.
            let spans: [(start: Double, end: Double)] = track.map { point in
                let full = point.seconds - window / 2
                if full + window <= total + 0.001 { return (full, full + window) }
                return (2 * point.seconds - total, total)
            }
            print("EchoRemoverTests: \(seconds) s: windows \(spans)")
            XCTAssertEqual(try XCTUnwrap(spans.first).start, 0, accuracy: 0.001, "\(seconds) s: first start")
            for (a, b) in zip(spans, spans.dropFirst()) {
                XCTAssertLessThanOrEqual(b.start, a.end + 0.001, "\(seconds) s: gap between windows")
                XCTAssertGreaterThan(b.start, a.start, "\(seconds) s: windows in order")
            }
            XCTAssertEqual(try XCTUnwrap(spans.last).end, total, accuracy: 0.001, "\(seconds) s: last end")
        }
    }

    /// From the M3.2 re-check: a 27 s part whose far side talks only at 0-7 s still gets cleaned.
    func testFarSideOnlyAtTheStartOfA27sPartIsStillCleaned() throws {
        let frames = 27 * EchoLab.rate
        let far = EchoLab.only(EchoLab.speech(frames: frames, seed: 95, rms: 0.1), seconds: 0...7)
        let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(frames, seed: 5, rms: 0.0003))
        let (_, out) = try XCTUnwrap(try clean(mic: mic, system: far))
        let reduction = EchoLab.reductionDB(input: mic, output: out, from: 2, to: 7)
        print("EchoRemoverTests: 27 s, far side 0-7 s: reduced by \(reduction) dB")
        XCTAssertGreaterThanOrEqual(reduction, 20)
    }

    /// From the M3.2 re-check: under 2 s of far side is under the fit's minimum, and a lag
    /// peak may well be found in it. Nothing is returned, nothing is written, nothing crashes.
    func testVeryShortFilesWhereAPeakCouldBeFoundReturnNil() throws {
        for seconds in [0.5, 1.0, 1.5, 1.99] {
            let frames = Int(seconds * rate)
            let far = EchoLab.speech(frames: frames, seed: 94, rms: 0.1)
            let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(frames, seed: 5, rms: 0.0003))
            let found = try clean(mic: mic, system: far)
            XCTAssertNil(found, "\(seconds) s")
            XCTAssertFalse(exists("out.wav"))
        }
    }
}
