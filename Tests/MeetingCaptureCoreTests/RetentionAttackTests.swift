import XCTest

@testable import MeetingCaptureCore

/// Sidecars are plain files in a folder, so retention has to treat them as untrusted.
/// The security review rated a planted sidecar low; these keep that true.
final class RetentionAttackTests: AudioTestCase {

    private func clean(days: Int = 30) -> [String] {
        AudioRetention.clean(in: dir, days: days, now: now).map(\.lastPathComponent)
    }

    // MARK: Age

    func testTheLimitIsExactlyTheDaysSet() throws {
        try touch("edge.m4a")
        try touch("past.m4a")
        try saveSidecar("edge", transcribed(ageDays: 30, files: ["edge.m4a"]))
        let justPast = now.addingTimeInterval(-30 * 86_400 - 1)
        try saveSidecar(
            "past",
            RecordingSidecar(createdAt: justPast, state: .processed, transcribedAt: justPast, audioFiles: ["past.m4a"]))
        XCTAssertEqual(clean(), ["past.m4a"])
    }

    func testAgeCountsFromTranscriptionNotFromRecording() throws {
        try touch("m.m4a")
        var value = transcribed(ageDays: 1, files: ["m.m4a"])
        value.createdAt = now.addingTimeInterval(-400 * 86_400)
        try saveSidecar("m", value)
        XCTAssertEqual(clean(), [])
    }

    func testADateInTheFutureKeepsTheAudio() throws {
        try touch("m.m4a")
        try saveSidecar("m", transcribed(ageDays: -100, files: ["m.m4a"]))
        XCTAssertEqual(clean(days: 1), [])
    }

    func testNegativeDaysDeleteNothing() throws {
        try touch("m.m4a")
        try saveSidecar("m", transcribed(ageDays: 400, files: ["m.m4a"]))
        XCTAssertEqual(clean(days: -1), [])
        XCTAssertEqual(clean(days: 0), [])
        XCTAssertTrue(exists("m.m4a"))
    }

    func testCleaningTwiceReportsADeletionOnce() throws {
        try touch("m.m4a")
        try saveSidecar("m", transcribed(ageDays: 40, files: ["m.m4a", "m.m4a"]))
        XCTAssertEqual(clean(), ["m.m4a"])
        XCTAssertEqual(clean(), [])
    }

    // MARK: Sidecars that say the wrong thing

    func testASidecarStillRecordingDeletesNothingWhateverElseItClaims() throws {
        try touch("m.m4a")
        var value = transcribed(ageDays: 400, files: ["m.m4a"])
        value.state = .recording
        try saveSidecar("m", value)
        XCTAssertEqual(clean(), [])
    }

    func testProcessedWithoutATranscriptDateDeletesNothing() throws {
        try touch("m.m4a")
        var value = transcribed(ageDays: 400, files: ["m.m4a"])
        value.transcribedAt = nil
        try saveSidecar("m", value)
        XCTAssertEqual(clean(), [])
    }

    func testAnUnreadableSidecarKeepsAudioAndIsNeverOfferedForDeletion() throws {
        let bad = [
            #"{"version":1,"createdAt":"not a date","state":"processed"}"#,
            #"{"version":1,"createdAt":"2020-01-01T00:00:00Z","state":"archived","audioFiles":["m.wav"]}"#,
            #"{"version":1,"state":"processed","transcribedAt":"2020-01-01T00:00:00Z","audioFiles":["m.wav"]}"#,
            "[]",
            "",
        ]
        try touch("m.wav")
        for text in bad {
            try Data(text.utf8).write(to: url("m.mcmeta.json"))
            XCTAssertEqual(clean(days: 1), [], text)
            XCTAssertEqual(AudioRetention.unmanagedWAVs(in: dir), [], "cleanup must not offer it: \(text)")
            XCTAssertEqual(AudioRetention.unfinished(in: dir), [], text)
        }
        XCTAssertTrue(exists("m.wav"))
    }

    func testASidecarFromANewerVersionStillReads() throws {
        try touch("m.m4a")
        let text = #"""
            {"version":9,"createdAt":"2020-01-01T00:00:00Z","state":"processed","transcribedAt":"2020-01-01T00:00:00Z",
            "speakerNames":{},"audioFiles":["m.m4a"],"somethingNew":{"a":1}}
            """#
        try Data(text.utf8).write(to: url("m.mcmeta.json"))
        XCTAssertEqual(clean(), ["m.m4a"], "ignoring new fields is what lets old builds keep managing it")
    }

    // MARK: Sidecars naming things they shouldn't

    func testASidecarInASubfolderCantReachUp() throws {
        try touch("real.m4a")
        let sub = url("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try transcribed(ageDays: 400, files: ["../real.m4a"]).save(to: sub.appendingPathComponent("x.mcmeta.json"))
        XCTAssertEqual(AudioRetention.clean(in: sub, days: 30, now: now), [])
        XCTAssertTrue(exists("real.m4a"))
    }

    func testRetentionDoesntWalkIntoSubfolders() throws {
        let sub = url("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try touch("sub/deep.m4a")
        try transcribed(ageDays: 400, files: ["deep.m4a"]).save(to: sub.appendingPathComponent("x.mcmeta.json"))
        XCTAssertEqual(clean(), [])
        XCTAssertTrue(exists("sub/deep.m4a"))
    }

    /// Security review: unconfirmed whether a symlink is followed. Removing it must take
    /// the link only, never what it points at.
    func testAListedSymlinkLosesTheLinkAndNeverItsTarget() throws {
        let outsideFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideFolder) }
        let outside = outsideFolder.appendingPathComponent("elsewhere.m4a")
        try Data("someone's audio".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url("link.m4a"), withDestinationURL: outside)
        try saveSidecar("x", transcribed(ageDays: 400, files: ["link.m4a"]))

        _ = clean()

        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "someone's audio")
    }

    func testASymlinkedFolderIsntEmptied() throws {
        let outsideFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideFolder) }
        let keep = outsideFolder.appendingPathComponent("keep.m4a")
        try Data("x".utf8).write(to: keep)
        try FileManager.default.createSymbolicLink(at: url("link.wav"), withDestinationURL: outsideFolder)
        try saveSidecar("x", transcribed(ageDays: 400, files: ["link.wav"]))

        _ = clean()

        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    /// `removeItem` deletes a folder and all it holds, and a folder can be called anything.
    func testAFolderNamedLikeAudioIsNotDeleted() throws {
        try FileManager.default.createDirectory(at: url("album.wav"), withIntermediateDirectories: false)
        try touch("album.wav/track.txt")
        try saveSidecar("x", transcribed(ageDays: 400, files: ["album.wav"]))
        _ = clean()
        XCTAssertTrue(exists("album.wav/track.txt"), "only audio files may go")
    }

    /// Deep review 6's neighbour: name matching is gone, but a sidecar can still claim
    /// another recording's file outright, and that recording's own age is ignored.
    func testASidecarCantDeleteAFileAnotherSidecarIsKeeping() throws {
        try touch("young.m4a")
        try saveSidecar("young", transcribed(ageDays: 1, files: ["young.m4a"]))
        try saveSidecar("planted", transcribed(ageDays: 400, files: ["young.m4a"]))
        _ = clean()
        XCTAssertTrue(exists("young.m4a"), "it was transcribed yesterday and has its own sidecar")
    }

    func testAnUnmanagedFileCantBeClaimedByAPlantedSidecar() throws {
        // A plain WAV from an older version, with no sidecar of its own: D-10 keeps those.
        try touch("from_2024.wav")
        try saveSidecar("planted", transcribed(ageDays: 400, files: ["from_2024.wav"]))
        _ = clean()
        XCTAssertTrue(exists("from_2024.wav"))
    }

    /// The guards above must not block the normal path: a part with no sidecar of its own,
    /// listed by the recording it belongs to, goes with it.
    func testEveryListedPartOfTheRecordingGoesWhenNoOtherSidecarOwnsIt() throws {
        for name in ["m.m4a", "m_part2.m4a", "m_part3.wav"] { try touch(name) }
        try touch("m.txt")
        try saveSidecar("m", transcribed(ageDays: 40, files: ["m.m4a", "m_part2.m4a", "m_part3.wav"]))
        XCTAssertEqual(clean(), ["m.m4a", "m_part2.m4a", "m_part3.wav"])
        XCTAssertTrue(exists("m.txt"), "the transcript stays")
        XCTAssertTrue(exists("m.mcmeta.json"), "and so does the sidecar")
    }

    /// A part archived while another failed stays a WAV, so the recording isn't "transcribed".
    func testARecordingWithOnePartKeptAsAWAVIsNotMarkedTranscribedAndKeepsItsAudio() async throws {
        struct FailsOnPartTwo: AudioEncoding {
            func encode(wav: URL, to m4a: URL) throws {
                if wav.lastPathComponent.contains("_part2") { throw CocoaError(.fileWriteOutOfSpace) }
                try AACEncoder().encode(wav: wav, to: m4a)
            }
        }
        let parts = [try wav("m.wav"), try wav("m_part2.wav")]
        let pipeline = RecordingPipeline(transcriber: ScriptedTranscriber(text: "invented words"), detector: nil)
        _ = try await RecordingPipeline.finish(
            parts: parts, base: url("m"), pipeline: pipeline, encoder: FailsOnPartTwo(), now: now)

        let saved = try XCTUnwrap(loadSidecar("m"))
        XCTAssertNil(saved.transcribedAt)
        XCTAssertEqual(saved.audioFiles, ["m.m4a", "m_part2.wav"])
        XCTAssertTrue(exists("m_part2.wav"))
        let later = now.addingTimeInterval(400 * 86_400)
        XCTAssertEqual(AudioRetention.clean(in: dir, days: 1, now: later), [], "nothing is deleted at any age")
        XCTAssertTrue(exists("m.m4a"))
        XCTAssertTrue(exists("m_part2.wav"))
    }

    // MARK: What --audio-cleanup may offer

    func testPartsOfARunningRecordingAreNeverOfferedForDeletion() throws {
        try touch("live.wav")
        try touch("live_part2.wav")
        var value = RecordingSidecar(createdAt: now, state: .recording)
        value.pid = getpid()
        try saveSidecar("live", value)
        XCTAssertEqual(AudioRetention.unmanagedWAVs(in: dir), [])
    }

    func testAWAVAFinishedRecordingKeptIsNotOffered() throws {
        try touch("m.wav")
        try touch("m_part2.wav")
        try saveSidecar("m", transcribed(ageDays: 1, files: ["m.wav", "m_part2.wav"]))
        XCTAssertEqual(AudioRetention.unmanagedWAVs(in: dir), [])
    }

    func testUnmanagedListIsSortedAndSkipsNonWAVs() throws {
        for name in ["b.wav", "a.WAV", "c.m4a", "d.txt"] { try touch(name) }
        XCTAssertEqual(AudioRetention.unmanagedWAVs(in: dir).map(\.lastPathComponent), ["a.WAV", "b.wav"])
    }

    // MARK: What the next launch offers

    func testAnUnfinishedRecordingMissingItsFirstPartIsStillOffered() throws {
        try touch("m_part2.wav")
        try saveSidecar("m", RecordingSidecar(createdAt: now, state: .recording))
        XCTAssertEqual(AudioRetention.unfinished(in: dir).map(\.lastPathComponent), ["m_part2.wav"])
    }

    func testAFinishedRecordingIsNotOfferedAgain() throws {
        try touch("m.m4a")
        try saveSidecar("m", transcribed(ageDays: 1, files: ["m.m4a"]))
        XCTAssertEqual(AudioRetention.unfinished(in: dir), [])
    }

    func testTwoUnfinishedRecordingsAreBothOfferedInNameOrder() throws {
        for base in ["b", "a"] {
            try touch("\(base).wav")
            try saveSidecar(base, RecordingSidecar(createdAt: now, state: .recording))
        }
        XCTAssertEqual(AudioRetention.unfinished(in: dir).map(\.lastPathComponent), ["a.wav", "b.wav"])
    }

    // MARK: --audio-cleanup answers

    private func answers(_ lines: String...) -> () -> String? {
        var queue = lines
        return { queue.isEmpty ? nil : queue.removeFirst() }
    }

    func testEndOfInputAtTheConfirmStepDeletesNothing() throws {
        let old = try wav("old.wav")
        XCTAssertEqual(AudioCleanup.run(in: dir, readLine: answers("d")).deleted, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testOnlyTheExactWordConfirms() throws {
        let old = try wav("old.wav")
        for wrong in ["DELETE", "Delete", "delete it", "yes", "d", ""] {
            XCTAssertEqual(AudioCleanup.run(in: dir, readLine: answers("d", wrong)).deleted, [], wrong)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testAnUnknownAnswerChangesNothing() throws {
        let old = try wav("old.wav")
        let result = AudioCleanup.run(in: dir, readLine: answers("x"))
        XCTAssertEqual(result.deleted + result.converted, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testConvertKeepsAWAVWhoseM4ACantBeProvenAndSaysSoInTheResult() throws {
        let old = try wav("old.wav")
        XCTAssertEqual(AudioCleanup.run(in: dir, encoder: FailingEncoder(), readLine: answers("c")).converted, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testConvertLeavesAnM4ANextToItAlone() throws {
        let old = try wav("old.wav")
        try touch("old.m4a", contents: Data("someone's own file".utf8))
        XCTAssertEqual(AudioCleanup.run(in: dir, readLine: answers("c")).converted, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: url("old.m4a"), encoding: .utf8), "someone's own file")
    }

    func testConvertRescuesAWAVACrashLeftWithNoLength() throws {
        let old = try wav("old.wav", seconds: 2)
        try TestAudio.crash(old)
        XCTAssertEqual(AudioCleanup.run(in: dir, readLine: answers("c")).converted.count, 1)
        XCTAssertEqual(try XCTUnwrap(RecordingFiles.duration(ofAudioAt: url("old.m4a").path)), 2, accuracy: 0.5)
    }

    func testDeleteTakesOnlyTheListedWAVs() throws {
        try wav("old.wav")
        try touch("keep.m4a")
        try touch("keep.txt")
        XCTAssertEqual(AudioCleanup.run(in: dir, readLine: answers("d", "delete")).deleted.count, 1)
        XCTAssertEqual(try names(), ["keep.m4a", "keep.txt"])
    }

    func testAFolderNamedLikeAWAVIsNotOfferedForDeletion() throws {
        try FileManager.default.createDirectory(at: url("album.wav"), withIntermediateDirectories: false)
        try touch("album.wav/track.txt")
        _ = AudioCleanup.run(in: dir, readLine: answers("d", "delete"))
        XCTAssertTrue(exists("album.wav/track.txt"))
    }

    func testAnEmptyFolderAsksNothing() {
        var asked = false
        let result = AudioCleanup.run(in: dir) {
            asked = true
            return "d"
        }
        XCTAssertFalse(asked)
        XCTAssertEqual(result.deleted + result.converted, [])
    }
}
