import XCTest

@testable import MeetingCaptureCore

/// Spec 05.2 / D-94: the library shows each report's group, and the public `ReportGroups`
/// facade the desktop app uses does what the store does.
final class GroupLibraryTests: GroupTestCase {

    private func entry(_ name: String) throws -> LibraryEntry {
        try XCTUnwrap(Library.entries(in: dir).first { $0.base.lastPathComponent == name }, name)
    }

    func testEntriesCarryTheirGroupAndUngroupedOnesHaveNone() throws {
        try addRecording("meeting_in", hoursAgo: 3, report: simpleReport(topic: "In"))
        try addRecording("meeting_out", hoursAgo: 5, report: simpleReport(topic: "Out"))
        let g = try makeGroup(["meeting_in"], name: "Series")
        XCTAssertEqual(try entry("meeting_in").group?.id, g.id)
        XCTAssertEqual(try entry("meeting_in").group?.name, "Series")
        XCTAssertNil(try entry("meeting_out").group)
    }

    func testEntriesInTwoGroupsEachShowTheirOwn() throws {
        try addRecording("meeting_a", hoursAgo: 3, report: simpleReport(topic: "A"))
        try addRecording("meeting_b", hoursAgo: 5, report: simpleReport(topic: "B"))
        let g1 = try GroupStore.create(named: "One", in: dir)
        let g2 = try GroupStore.create(named: "Two", in: dir)
        try GroupStore.add("meeting_a", to: g1.id, in: dir)
        try GroupStore.add("meeting_b", to: g2.id, in: dir)
        XCTAssertEqual(try entry("meeting_a").group?.name, "One")
        XCTAssertEqual(try entry("meeting_b").group?.name, "Two")
    }

    func testAnUnreadableGroupsFileGivesNoGroupAndTheListStillLoads() throws {
        try addRecording("meeting_a", hoursAgo: 3, report: simpleReport(topic: "A"))
        try Data("garbage".utf8).write(to: GroupStore.url(in: dir))
        XCTAssertNil(try entry("meeting_a").group)
        XCTAssertEqual(Library.entries(in: dir).count, 1)
    }

    func testGroupsJSONIsNotListedAsARecording() throws {
        try addRecording("meeting_a", hoursAgo: 3, report: simpleReport(topic: "A"))
        try makeGroup(["meeting_a"])
        XCTAssertEqual(Library.entries(in: dir).map { $0.base.lastPathComponent }, ["meeting_a"])
    }

    // MARK: the facade

    func testTheFacadeMakesRenamesAddsRemovesAndDeletesGroups() throws {
        try addRecording("meeting_a", hoursAgo: 3, report: simpleReport(topic: "A"))
        let g = try ReportGroups.create(named: "Weekly", in: dir)
        XCTAssertEqual(try ReportGroups.all(in: dir).map(\.name), ["Weekly"])
        try ReportGroups.rename(g, to: "Weekly sync", in: dir)
        XCTAssertEqual(try ReportGroups.all(in: dir).map(\.name), ["Weekly sync"])
        let g2 = try XCTUnwrap(try ReportGroups.all(in: dir).first)

        try ReportGroups.add(try entry("meeting_a"), to: g2)
        XCTAssertEqual(try entry("meeting_a").group?.name, "Weekly sync")
        try ReportGroups.remove(try entry("meeting_a"))
        XCTAssertNil(try entry("meeting_a").group)
        XCTAssertTrue(exists("meeting_a.report.json"), "taking a report out keeps the report")

        try ReportGroups.add(try entry("meeting_a"), to: g2)
        try ReportGroups.delete(g2, in: dir)
        XCTAssertEqual(try ReportGroups.all(in: dir), [])
        XCTAssertTrue(exists("meeting_a.report.json"), "deleting a group keeps its reports")
        XCTAssertTrue(exists("meeting_a.txt"))
    }

    func testTheFacadeRefusesADuplicateNameAndReportsAnUnreadableFile() throws {
        try ReportGroups.create(named: "Weekly", in: dir)
        XCTAssertThrowsError(try ReportGroups.create(named: "weekly", in: dir))
        try Data("x".utf8).write(to: GroupStore.url(in: dir))
        XCTAssertThrowsError(try ReportGroups.all(in: dir)) { XCTAssertEqual($0 as? GroupError, .unreadable) }
        XCTAssertNotNil((GroupError.unreadable as LocalizedError).errorDescription)
    }

    func testEveryGroupErrorHasAReadableMessage() {
        let all: [GroupError] = [
            .unreadable, .newerFile, .badName, .nameTaken("X"), .noSuchGroup, .badMember, .unknownScenario("y"),
            .redactionOffGlobally,
        ]
        for e in all { XCTAssertFalse((e.errorDescription ?? "").isEmpty, "\(e)") }
    }

    func testTheFacadeListsTheScenariosAGroupCanPin() {
        let names = ReportGroups.scenarioChoices.map(\.name)
        for built in ["meeting", "therapy", "interview", "one_on_one", "lecture", "general"] {
            XCTAssertTrue(names.contains(built), built)
        }
    }
}
