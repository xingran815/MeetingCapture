import XCTest

@testable import MeetingCaptureCore

final class RecordingDiscardTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("mc-discard-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        dir = dir.resolvingSymlinksInPath()
    }

    override func tearDown() { try? fm.removeItem(at: dir) }

    private var base: URL { dir.appendingPathComponent("20261114_090000") }

    @discardableResult
    private func touch(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func sidecar(
        base b: URL? = nil, state: RecordingSidecar.State = .recording, pid: Int32? = getpid(),
        audio: [String]? = nil, reports: [String]? = nil
    ) throws {
        var s = RecordingSidecar(createdAt: Date(), state: state, pid: pid)
        s.audioFiles = audio
        s.reportFiles = reports
        try s.save(to: RecordingSidecar.url(forBase: b ?? base))
    }

    /// A fake remover that records the URLs in order and really moves nothing.
    private final class Recorder {
        var urls: [URL] = []
        var failOn: String?
        func callAsFunction(_ url: URL) throws {
            if url.lastPathComponent == failOn { throw NSError(domain: "t", code: 1) }
            urls.append(url)
        }
    }

    func testMovesOwnPartsThenSidecarLast() throws {
        let a = try touch("20261114_090000.wav")
        let b = try touch("20261114_090000_part2.wav")
        let m = try touch("20261114_090000.m4a")
        try sidecar()
        let r = Recorder()
        let moved = try RecordingDiscard.trash(base: base, parts: [a, b, m], pid: getpid(), remover: r.callAsFunction)
        XCTAssertEqual(
            moved.map(\.lastPathComponent),
            [
                "20261114_090000.wav", "20261114_090000_part2.wav", "20261114_090000.m4a",
                "20261114_090000.mcmeta.json",
            ])
        XCTAssertEqual(r.urls, moved)
    }

    func testSimilarlyNamedFilesOfOtherRecordingsSurvive() throws {
        // D-44: a similarly named file must never go with this recording.
        let own = try touch("20261114_090000.wav")
        let near = try touch("20261114_0900002.wav")
        let other = try touch("20261114_100000.wav")
        let clean = try touch("20261114_090000_clean.m4a")
        let notAudio = try touch("20261114_090000.txt")
        try sidecar()
        let r = Recorder()
        let moved = try RecordingDiscard.trash(
            base: base, parts: [own, near, other, clean, notAudio], pid: getpid(), remover: r.callAsFunction)
        XCTAssertEqual(moved.map(\.lastPathComponent), ["20261114_090000.wav", "20261114_090000.mcmeta.json"])
        for u in [near, other, clean, notAudio] { XCTAssertFalse(r.urls.contains(u)) }
    }

    func testPartsInAnotherFolderAreSkipped() throws {
        let elsewhere = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let foreign = try touch("20261114_090000.wav", in: elsewhere)
        try sidecar()
        let r = Recorder()
        let moved = try RecordingDiscard.trash(base: base, parts: [foreign], pid: getpid(), remover: r.callAsFunction)
        XCTAssertEqual(moved.map(\.lastPathComponent), ["20261114_090000.mcmeta.json"])
        XCTAssertTrue(fm.fileExists(atPath: foreign.path))
    }

    func testSymlinksAndDirectoriesAreSkipped() throws {
        let target = try touch("precious.wav")
        let link = dir.appendingPathComponent("20261114_090000.wav")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let folder = dir.appendingPathComponent("20261114_090000_part2.wav")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try sidecar()
        let r = Recorder()
        let moved = try RecordingDiscard.trash(
            base: base, parts: [link, folder], pid: getpid(), remover: r.callAsFunction)
        XCTAssertEqual(moved.map(\.lastPathComponent), ["20261114_090000.mcmeta.json"])
    }

    func testFilesAnotherSidecarListsAreSkipped() throws {
        let mine = try touch("20261114_090000.wav")
        let claimed = try touch("20261114_090000_part2.wav")
        try sidecar()
        let otherBase = dir.appendingPathComponent("20261114_110000")
        try sidecar(base: otherBase, state: .processed, pid: nil, audio: ["20261114_090000_part2.wav"])
        let r = Recorder()
        let moved = try RecordingDiscard.trash(
            base: base, parts: [mine, claimed], pid: getpid(), remover: r.callAsFunction)
        XCTAssertEqual(moved.map(\.lastPathComponent), ["20261114_090000.wav", "20261114_090000.mcmeta.json"])
    }

    func testReportFilesListedByAnotherSidecarAreSkipped() throws {
        // claimedByOthers also covers reportFiles; a wav named there is not ours.
        let w = try touch("20261114_090000.wav")
        try sidecar()
        try sidecar(
            base: dir.appendingPathComponent("zz"), state: .processed, pid: nil, reports: ["20261114_090000.wav"])
        let r = Recorder()
        let moved = try RecordingDiscard.trash(base: base, parts: [w], pid: getpid(), remover: r.callAsFunction)
        XCTAssertEqual(moved.map(\.lastPathComponent), ["20261114_090000.mcmeta.json"])
    }

    func testNoSidecarMovesNothing() throws {
        let w = try touch("20261114_090000.wav")
        let r = Recorder()
        XCTAssertThrowsError(
            try RecordingDiscard.trash(base: base, parts: [w], pid: getpid(), remover: r.callAsFunction)
        ) {
            XCTAssertEqual($0 as? RecordingDiscard.DiscardError, .notThisRecording("20261114_090000"))
        }
        XCTAssertTrue(r.urls.isEmpty)
    }

    func testProcessedSidecarMovesNothing() throws {
        let w = try touch("20261114_090000.wav")
        try sidecar(state: .processed)
        let r = Recorder()
        XCTAssertThrowsError(
            try RecordingDiscard.trash(base: base, parts: [w], pid: getpid(), remover: r.callAsFunction))
        XCTAssertTrue(r.urls.isEmpty)
    }

    func testOtherProcessSidecarMovesNothing() throws {
        let w = try touch("20261114_090000.wav")
        try sidecar(pid: getpid() &+ 1)
        let r = Recorder()
        XCTAssertThrowsError(
            try RecordingDiscard.trash(base: base, parts: [w], pid: getpid(), remover: r.callAsFunction)
        ) {
            XCTAssertEqual($0 as? RecordingDiscard.DiscardError, .notThisRecording("20261114_090000"))
        }
        XCTAssertThrowsError(try RecordingDiscard.trash(base: base, parts: [w], pid: 1, remover: r.callAsFunction))
        XCTAssertTrue(r.urls.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: w.path))
    }

    func testEmptyPartsTriesOnlyFirstWav() throws {
        try touch("20261114_090000.wav")
        try touch("20261114_090000_part2.wav")
        try sidecar()
        let r = Recorder()
        let moved = try RecordingDiscard.trash(base: base, parts: [], pid: getpid(), remover: r.callAsFunction)
        XCTAssertEqual(moved.map(\.lastPathComponent), ["20261114_090000.wav", "20261114_090000.mcmeta.json"])
    }

    func testEmptyPartsWithNoWavStillMovesSidecar() throws {
        try sidecar()
        let r = Recorder()
        let moved = try RecordingDiscard.trash(base: base, parts: [], pid: getpid(), remover: r.callAsFunction)
        XCTAssertEqual(moved.map(\.lastPathComponent), ["20261114_090000.mcmeta.json"])
    }

    func testDuplicatePartsMoveOnce() throws {
        let w = try touch("20261114_090000.wav")
        try sidecar()
        let r = Recorder()
        let moved = try RecordingDiscard.trash(base: base, parts: [w, w], pid: getpid(), remover: r.callAsFunction)
        XCTAssertEqual(moved.count, 2)
    }

    func testFailureStopsAtFirstAndKeepsSidecar() throws {
        let a = try touch("20261114_090000.wav")
        let b = try touch("20261114_090000_part2.wav")
        let c = try touch("20261114_090000_part3.wav")
        try sidecar()
        let r = Recorder()
        r.failOn = "20261114_090000_part2.wav"
        XCTAssertThrowsError(
            try RecordingDiscard.trash(base: base, parts: [a, b, c], pid: getpid(), remover: r.callAsFunction)
        ) {
            guard case .moveFailed(let file, _)? = $0 as? RecordingDiscard.DiscardError else {
                return XCTFail("\($0)")
            }
            XCTAssertEqual(file, "20261114_090000_part2.wav")
        }
        XCTAssertEqual(r.urls.map(\.lastPathComponent), ["20261114_090000.wav"])
        XCTAssertTrue(
            fm.fileExists(atPath: RecordingSidecar.url(forBase: base).path),
            "sidecar stays so the next launch offers the rest")
    }

    func testSidecarFailureAfterAudioIsReported() throws {
        let a = try touch("20261114_090000.wav")
        try sidecar()
        let r = Recorder()
        r.failOn = "20261114_090000.mcmeta.json"
        XCTAssertThrowsError(
            try RecordingDiscard.trash(base: base, parts: [a], pid: getpid(), remover: r.callAsFunction))
        XCTAssertEqual(r.urls.map(\.lastPathComponent), ["20261114_090000.wav"])
    }
}
