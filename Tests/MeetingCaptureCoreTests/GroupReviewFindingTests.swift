import XCTest

@testable import MeetingCaptureCore

/// Tests named for the M5.2 review's findings (nits 1, 2, 3, 5, 6; #1 and #2 are in
/// GroupPipelineTests).
final class GroupReviewFindingTests: GroupTestCase {

    private let reviewSentence = "The review checked this report against its own transcript only"

    private func context(_ members: [String]) throws -> GroupContext {
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName] + members)
        return try XCTUnwrap(GroupContextBuilder.build(for: base))
    }

    // MARK: nit 1: no sidecar, the date comes from the name's stamp

    func testM52ReviewNit1AReRunOfAnOlderReportWithNoSidecarDoesNotMakeItNewer() throws {
        let older = "meeting_20261101_100000"
        let newer = "meeting_20261108_100000"
        for (n, t) in [(older, "TopicOlder"), (newer, "TopicNewer")] {
            try JSONEncoder().encode(simpleReport(topic: t)).write(to: Notebook.reportURL(forBase: url(n)))
        }
        // The older one's report.json is rewritten after the newer one's, as a re-run does.
        Thread.sleep(forTimeInterval: 1.1)
        try JSONEncoder().encode(simpleReport(topic: "TopicOlder")).write(to: Notebook.reportURL(forBase: url(older)))
        try makeGroup([older, newer])
        let forNewer = try XCTUnwrap(GroupContextBuilder.build(for: url(newer)))
        XCTAssertEqual(forNewer.used, ["TopicOlder"], "\(forNewer.leftOut)")
        let forOlder = try XCTUnwrap(GroupContextBuilder.build(for: url(older)))
        XCTAssertEqual(forOlder.used, [])
        XCTAssertEqual(forOlder.leftOut, [.init(title: "TopicNewer", reason: .later)])
    }

    func testM52ReviewNit1TheNameStampIsParsedAndASidecarStillWins() throws {
        XCTAssertNotNil(GroupContextBuilder.stampDate("meeting_20261107_093000"))
        XCTAssertNil(GroupContextBuilder.stampDate("meeting_notes"))
        // A sidecar date beats a name's stamp.
        try addRecording("meeting_20991231_235959", hoursAgo: 50, report: simpleReport(topic: "TopicSidecar"))
        let d = try XCTUnwrap(GroupContextBuilder.createdAt(of: url("meeting_20991231_235959")))
        XCTAssertEqual(d, now.addingTimeInterval(-50 * hour))
    }

    // MARK: nit 2: the "review checked" sentence only when the review ran and context was used

    private func notices(review: Bool = true, failReview: Bool = false, withUsed: Bool = true) async throws -> [String]
    {
        try addRecording("meeting_a", hoursAgo: 3, report: simpleReport(topic: "TopicA"))
        let c = try context(withUsed ? ["meeting_a"] : [])
        let b = echoBackend()
        if failReview {
            let inner = b.onComplete
            b.onComplete = { call in
                if call.tier == .frontier { throw StepFailure() }
                return try inner(call)
            }
        }
        var p = ReportFixtures.pipeline(b)
        p.review = review
        return try await p.run(transcript: transcriptText, context: c).report.notices
    }

    func testM52ReviewNit2TheSentenceIsPresentWhenTheReviewRanAndContextWasUsed() async throws {
        let n = try await notices()
        XCTAssertTrue(n.joined().contains(reviewSentence), "\(n)")
    }

    func testM52ReviewNit2TheSentenceIsAbsentWhenTheReviewFails() async throws {
        let n = try await notices(failReview: true)
        XCTAssertFalse(n.joined().contains(reviewSentence), "\(n)")
        XCTAssertTrue(n.joined().contains("\"TopicA\""), "the used report is still named")
    }

    func testM52ReviewNit2TheSentenceIsAbsentWhenTheReviewIsOff() async throws {
        let n = try await notices(review: false)
        XCTAssertFalse(n.joined().contains(reviewSentence), "\(n)")
    }

    func testM52ReviewNit2TheSentenceIsAbsentWhenNoContextWasUsed() async throws {
        let n = try await notices(withUsed: false)
        XCTAssertFalse(n.joined().contains(reviewSentence), "\(n)")
    }

    // MARK: nit 3: one report's notes are capped

    func testM52ReviewNit3ThirtyThousandCharactersOfNotesAreCutAndTheReportAndAnOlderOneAreStillUsed() throws {
        var on = ReportEdits()
        on.sendNotesToLLM = true
        try addRecording(
            "meeting_big_notes", hoursAgo: 3, report: simpleReport(topic: "TopicBigNotes"), edits: on,
            notes: String(repeating: "§", count: 30_000))
        try addRecording("meeting_older", hoursAgo: 9, report: simpleReport(topic: "TopicOlder"))
        let c = try context(["meeting_big_notes", "meeting_older"])
        let count = c.text.filter { $0 == "§" }.count
        XCTAssertGreaterThan(count, 0, "some notes go")
        XCTAssertLessThanOrEqual(count, GroupContextBuilder.maxNotesPerReport)
        XCTAssertEqual(c.used, ["TopicBigNotes", "TopicOlder"], "\(c.leftOut)")
        XCTAssertLessThan(c.text.count, GroupContextBuilder.maxCharacters)
    }

    // MARK: nit 5: groups.json changes hold a lock

    func testM52ReviewNit5TwoThreadsCreating25GroupsEachLeaveFifty() throws {
        let errors = NSLock()
        var failures: [Error] = []
        let dir = self.dir!
        DispatchQueue.concurrentPerform(iterations: 2) { t in
            for i in 0..<25 {
                do { try GroupStore.create(named: "thread\(t)-group\(i)", in: dir) } catch {
                    errors.lock()
                    failures.append(error)
                    errors.unlock()
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        let groups = try GroupStore.load(in: dir)
        XCTAssertEqual(groups.count, 50)
        XCTAssertEqual(Set(groups.map(\.name)).count, 50)
    }

    // MARK: nit 6: a hand-written groups.json

    func testM52ReviewNit6AFileWithoutAVersionLoads() throws {
        try Data(#"{"groups": [{"id": "g1", "name": "By hand", "members": ["meeting_a"]}]}"#.utf8)
            .write(to: GroupStore.url(in: dir))
        let g = try XCTUnwrap(try GroupStore.load(in: dir).first)
        XCTAssertEqual(g.name, "By hand")
        XCTAssertEqual(g.members, ["meeting_a"])
        // And a change keeps it and writes a version.
        try GroupStore.create(named: "Second", in: dir)
        XCTAssertEqual(try GroupStore.load(in: dir).count, 2)
    }

    func testM52ReviewNit6AnEmptyObjectLoadsAsNoGroups() throws {
        try Data("{}".utf8).write(to: GroupStore.url(in: dir))
        XCTAssertEqual(try GroupStore.load(in: dir), [])
        XCTAssertNoThrow(try GroupStore.create(named: "First", in: dir))
    }
}
