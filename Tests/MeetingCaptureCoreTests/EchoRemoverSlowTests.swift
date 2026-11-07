import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// Slow echo-remover edge cases (>3 s each), run by `check.sh` and skipped in CI (D-77). The core remover tests stay in `EchoRemoverTests`.
final class EchoRemoverSlowTests: EchoRemoverTestCase {

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
}

/// More slow echo-remover cases, a separate job so no slow class passes ~45 s (D-77).
final class EchoRemoverEdgeSlowTests: EchoRemoverTestCase {

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
}

/// M3.2 deep review, finding 1, the +300 ppm half. This was one 88 s test running both signs; split so each half is its own ~40 s job (D-77).
/// A class with one test prints "Executed 1 test" (singular), which check.sh does not count, so this class also holds testAShortDelayIsRemovedToo.
final class EchoRemoverDriftSlowTests: EchoRemoverTestCase {

    /// Split from `testACleanedPartKeepsItsReductionWithAFastMicClock`, which ran both signs in 88 s (D-77). Same assertions.
    func testACleanedPartKeepsItsReductionWithAFastMicClockPlus300PPM() throws {
        try assertAPartKeepsItsReductionWithAMicClock(ppm: 300.0)
    }

    func testAShortDelayIsRemovedToo() throws {
        let far = EchoLab.speech(seconds: 24, seed: 12, rms: 0.1)
        let mic = EchoLab.sum(EchoLab.echo(of: far, delay: 1_440), EchoLab.noise(far.count, seed: 6, rms: 0.0003))
        let (result, out) = try XCTUnwrap(try clean(mic: mic, system: far))
        XCTAssertEqual(result.lagSeconds, 0.030, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(EchoLab.reductionDB(input: mic, output: out, from: 6, to: 23.5), 30)
    }
}

/// M3.2 deep review, finding 1, the -300 ppm half (split from the +300 test, D-77).
/// A class with one test prints "Executed 1 test" (singular), which check.sh does not count, so this class also holds testTheLastFramesOfTheFileAreCleanedToo.
final class EchoRemoverDriftMinusSlowTests: EchoRemoverTestCase {

    /// Split from `testACleanedPartKeepsItsReductionWithAFastMicClock`, which ran both signs in 88 s (D-77). Same assertions.
    func testACleanedPartKeepsItsReductionWithAFastMicClockMinus300PPM() throws {
        try assertAPartKeepsItsReductionWithAMicClock(ppm: -300.0)
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
}
