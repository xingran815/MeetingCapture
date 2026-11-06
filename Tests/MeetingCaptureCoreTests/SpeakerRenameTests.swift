import XCTest

@testable import MeetingCaptureCore

/// Rename rewrites the only transcript, so it mustn't touch a word of what was said.
final class SpeakerRenameTests: AudioTestCase {

    // MARK: Labels

    func testRenamingOneLabelLeavesOneThatStartsTheSame() {
        let text = "[00:00:01] Speaker 1: a\n[00:00:02] Speaker 1 (part 2): b\n[00:00:03] Speaker 10: c"
        XCTAssertEqual(
            SpeakerLabels.rename("Speaker 1", to: "Ana", in: text),
            "[00:00:01] Ana: a\n[00:00:02] Speaker 1 (part 2): b\n[00:00:03] Speaker 10: c")
        XCTAssertEqual(
            SpeakerLabels.rename("Speaker 1 (part 2)", to: "Ana", in: text),
            "[00:00:01] Speaker 1: a\n[00:00:02] Ana: b\n[00:00:03] Speaker 10: c")
    }

    func testANewNameIsTakenLiterally() {
        for name in ["$1", #"\0"#, "a.*b", "(x)", "Ana & Bea", "José"] {
            XCTAssertEqual(
                SpeakerLabels.rename("You", to: name, in: "[00:00:01] You: hi"), "[00:00:01] \(name): hi", name)
        }
    }

    func testAnOldNameWithRegexCharactersIsTakenLiterally() {
        let text = "[00:00:01] a.c: one\n[00:00:02] abc: two"
        XCTAssertEqual(SpeakerLabels.rename("a.c", to: "Ana", in: text), "[00:00:01] Ana: one\n[00:00:02] abc: two")
    }

    func testRenamingToAndFromChineseAndEmojiLeavesEveryOtherCharacter() {
        let original = "[00:00:01] 🙂 王小明: 市场部 🎉 需要预算: 三万\n[00:00:02] Speaker 2: 好的 🙂"
        let there = SpeakerLabels.rename("🙂 王小明", to: "Ana 🇩🇪", in: original)
        XCTAssertEqual(there, "[00:00:01] Ana 🇩🇪: 市场部 🎉 需要预算: 三万\n[00:00:02] Speaker 2: 好的 🙂")
        XCTAssertEqual(SpeakerLabels.rename("Ana 🇩🇪", to: "🙂 王小明", in: there), original)
    }

    func testWordsThatLookLikeALineAreNotRewritten() {
        let text = "[00:00:01] You: [00:00:02] Speaker 1: is what I'd say\n[00:00:03] Speaker 1: real"
        XCTAssertEqual(
            SpeakerLabels.rename("Speaker 1", to: "Ana", in: text),
            "[00:00:01] You: [00:00:02] Speaker 1: is what I'd say\n[00:00:03] Ana: real")
    }

    func testAColonInTheWordsDoesntChangeTheLabel() {
        let text = "[00:00:01] You: the plan: ship it"
        XCTAssertEqual(SpeakerLabels.speakers(in: text), ["You"])
        XCTAssertEqual(SpeakerLabels.rename("You", to: "Ana", in: text), "[00:00:01] Ana: the plan: ship it")
    }

    func testRenamingANameNoOneHasChangesNothing() {
        let text = "[00:00:01] You: hi\n"
        XCTAssertEqual(SpeakerLabels.rename("Nobody", to: "Ana", in: text), text)
    }

    func testWindowsLineEndingsSurvive() {
        let text = "[00:00:01] You: a\r\n[00:00:02] You: b\r\n"
        XCTAssertEqual(SpeakerLabels.rename("You", to: "Ana", in: text), "[00:00:01] Ana: a\r\n[00:00:02] Ana: b\r\n")
    }

    func testLinesNotInTheFormatAreLeftAlone() {
        let text = "Notes from today\n\n[00:00:01] You: hi\nYou: not a line\n"
        XCTAssertEqual(
            SpeakerLabels.rename("You", to: "Ana", in: text),
            "Notes from today\n\n[00:00:01] Ana: hi\nYou: not a line\n")
    }

    func testANameThatWouldBreakTheFormatIsRefused() {
        for bad in ["", " ", "a:b", ":", "a\nb", "a\rb", "a\u{2028}b"] {
            XCTAssertNil(SpeakerLabels.validName(bad), bad)
        }
        XCTAssertEqual(SpeakerLabels.validName("  Dr. O'Brien-Smith (host) "), "Dr. O'Brien-Smith (host)")
    }

    // MARK: The file and the sidecar

    private func transcript(_ text: String) throws -> URL {
        let file = url("m.txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testRenameKeepsTheFieldsRetentionDependsOn() throws {
        let file = try transcript("[00:00:01] Speaker 1: hi\n")
        try saveSidecar("m", transcribed(ageDays: 3, files: ["m.m4a"]))
        try SpeakerLabels.rename("Speaker 1", to: "Ana", transcriptAt: file)
        let after = try XCTUnwrap(loadSidecar("m"))
        XCTAssertEqual(after.audioFiles, ["m.m4a"])
        XCTAssertEqual(after.transcribedAt, now.addingTimeInterval(-3 * 86_400))
        XCTAssertEqual(after.state, .processed)
    }

    func testRenameWithNoSidecarStillWorksAndMakesNone() throws {
        let file = try transcript("[00:00:01] You: hi\n")
        try SpeakerLabels.rename("You", to: "Ana", transcriptAt: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[00:00:01] Ana: hi\n")
        XCTAssertFalse(exists("m.mcmeta.json"))
    }

    func testRenameLeavesAnUnreadableSidecarForAPersonToFix() throws {
        let file = try transcript("[00:00:01] You: hi\n")
        try Data("not json".utf8).write(to: url("m.mcmeta.json"))
        try SpeakerLabels.rename("You", to: "Ana", transcriptAt: file)
        XCTAssertEqual(try String(contentsOf: url("m.mcmeta.json"), encoding: .utf8), "not json")
    }

    func testRenamingAMissingTranscriptThrowsAndCreatesNothing() {
        XCTAssertThrowsError(try SpeakerLabels.rename("You", to: "Ana", transcriptAt: url("gone.txt")))
        XCTAssertFalse(exists("gone.txt"))
    }

    /// `speakerNames` is documented as "label as first assigned" to "the name the user
    /// chose", so a second rename has to update that entry, not add a stale pair.
    func testRenamingTwiceRemembersTheLatestNameForTheFirstLabel() throws {
        let file = try transcript("[00:00:01] Speaker 1: hi\n")
        try saveSidecar("m", transcribed(ageDays: 1, files: []))
        try SpeakerLabels.rename("Speaker 1", to: "Ana", transcriptAt: file)
        try SpeakerLabels.rename("Ana", to: "Bea", transcriptAt: file)
        XCTAssertEqual(loadSidecar("m")?.speakerNames, ["Speaker 1": "Bea"])
    }

    // MARK: Turns

    func testExactlyOneSecondCountsAsATurn() {
        let turns = [SpeakerTurn(start: 0, end: 5, speaker: 0), SpeakerTurn(start: 5, end: 6, speaker: 1)]
        XCTAssertEqual(SpeakerLabels.mergeShortTurns(turns), turns)
    }

    func testTurnsArriveInAnyOrder() {
        let merged = SpeakerLabels.mergeShortTurns([
            SpeakerTurn(start: 10, end: 20, speaker: 1), SpeakerTurn(start: 0, end: 10, speaker: 0),
        ])
        XCTAssertEqual(merged.map(\.speaker), [0, 1])
    }

    func testAShortTurnBetweenTwoRunsOfOneSpeakerJoinsThem() {
        let merged = SpeakerLabels.mergeShortTurns([
            SpeakerTurn(start: 0, end: 5, speaker: 0), SpeakerTurn(start: 5, end: 5.5, speaker: 1),
            SpeakerTurn(start: 5.5, end: 10, speaker: 0),
        ])
        XCTAssertEqual(merged, [SpeakerTurn(start: 0, end: 10, speaker: 0)])
    }

    func testOverlappingLongTurnsKeepBothSpeakersAndTheLongOneKeepsItsEnd() {
        let merged = SpeakerLabels.mergeShortTurns([
            SpeakerTurn(start: 0, end: 30, speaker: 0), SpeakerTurn(start: 10, end: 20, speaker: 1),
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].end, 30)
    }

    func testAnEqualOverlapAlwaysGoesToTheSameSpeaker() {
        let turns = [SpeakerTurn(start: 0, end: 4, speaker: 8), SpeakerTurn(start: 4, end: 8, speaker: 3)]
        let segment = Transcriber.Segment(start: 3, end: 5, text: "x")
        XCTAssertEqual(SpeakerLabels.label([segment], turns: turns).map(\.speaker), ["Speaker 2"], "the lower id")
    }

    func testEverySegmentKeepsItsWordsWhateverTheTurnsLookLike() {
        // Every turn is short, so all of them merge away and the words must still come through.
        let turns = [SpeakerTurn(start: 0, end: 0.4, speaker: 0), SpeakerTurn(start: 0.5, end: 0.9, speaker: 1)]
        let segment = Transcriber.Segment(start: 0, end: 1, text: "kept")
        XCTAssertEqual(SpeakerLabels.label([segment], turns: turns).map(\.text), ["kept"])
    }

    func testWordSplittingNeverLosesAWord() {
        let turns = [SpeakerTurn(start: 0, end: 2, speaker: 0), SpeakerTurn(start: 2, end: 4, speaker: 1)]
        let words = [
            Transcriber.Word(start: 0, end: 1, text: " a"), Transcriber.Word(start: 1.9, end: 2.1, text: " b"),
            Transcriber.Word(start: 3, end: 3, text: " c"), Transcriber.Word(start: 9, end: 10, text: " d"),
        ]
        let out = SpeakerLabels.label(
            [Transcriber.Segment(start: 0, end: 10, text: " a b c d", words: words)], turns: turns)
        XCTAssertEqual(out.map(\.text).joined(), " a b c d")
    }

    func testAZeroLengthSegmentStillGetsASpeaker() {
        let turns = [SpeakerTurn(start: 0, end: 5, speaker: 0)]
        let out = SpeakerLabels.label([Transcriber.Segment(start: 2, end: 2, text: "x")], turns: turns)
        XCTAssertEqual(out.map(\.speaker), ["Speaker 1"])
    }

    // MARK: Format

    func testEachSegmentIsOneLineSoRenameCantBeFooled() {
        let line = LabelledSegment(start: 1, end: 2, speaker: "You", text: "one\n[00:00:09] Speaker 1: two")
        XCTAssertEqual(SpeakerLabels.format([line]).components(separatedBy: "\n").count, 1)
    }

    func testTimesPastAnHourAndAcrossDaysFormat() {
        let line = LabelledSegment(start: 3 * 3600 + 62.9, end: 11_000, speaker: "You", text: "x")
        XCTAssertEqual(SpeakerLabels.format([line]), "[03:01:02] You: x")
    }

    func testMergeOrdersByTimeAndTheMicGoesFirstOnATie() {
        let mic = [LabelledSegment(start: 1, end: 2, speaker: "You", text: "m")]
        let system = [
            LabelledSegment(start: 0, end: 1, speaker: "Speaker 1", text: "a"),
            LabelledSegment(start: 1, end: 2, speaker: "Speaker 1", text: "b"),
        ]
        XCTAssertEqual(SpeakerLabels.merge(mic: mic, system: system).map(\.text), ["a", "m", "b"])
    }

    // MARK: Stopping

    func testManyStopsAtOnceLetExactlyOneThrough() {
        let stopper = RecordingStopper()
        XCTAssertFalse(stopper.arm())
        let lock = NSLock()
        var wins = 0
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            if stopper.claimStop() {
                lock.lock()
                wins += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(wins, 1)
    }

    func testATimerStartedAfterAStopNeverFires() {
        let stopper = RecordingStopper()
        XCTAssertFalse(stopper.arm())
        XCTAssertTrue(stopper.claimStop())
        let inverted = expectation(description: "the timer must stay quiet")
        inverted.isInverted = true
        stopper.startTimer(after: 0.01) { inverted.fulfill() }
        wait(for: [inverted], timeout: 0.1)
    }

    func testSeveralEarlyStopsAreOneStop() {
        let stopper = RecordingStopper()
        XCTAssertFalse(stopper.claimStop())
        XCTAssertFalse(stopper.claimStop())
        XCTAssertTrue(stopper.arm())
        XCTAssertTrue(stopper.claimStop())
        XCTAssertFalse(stopper.claimStop())
    }

    func testPauseIsOnlyASpaceAndEnterWhateverTheLineEnding() {
        XCTAssertEqual(RecordingKeys.action(for: Data(" \r\n".utf8)), .pauseToggle)
        XCTAssertEqual(RecordingKeys.action(for: Data(" ".utf8)), .pauseToggle)
        XCTAssertEqual(RecordingKeys.action(for: Data("\r\n".utf8)), .stop)
        XCTAssertEqual(RecordingKeys.action(for: Data("  \n".utf8)), .stop)
    }
}
