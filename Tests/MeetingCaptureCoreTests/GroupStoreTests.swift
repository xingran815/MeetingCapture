import XCTest

@testable import MeetingCaptureCore

/// Spec 05.2 / D-94: `groups.json`, made by hand, keyed by base name, never overwritten
/// when it can't be read.
final class GroupStoreTests: GroupTestCase {

    // MARK: create and names

    func testNoFileIsNoGroups() throws {
        XCTAssertEqual(try GroupStore.load(in: dir), [])
        XCTAssertNil(GroupStore.group(of: "meeting_a", in: dir))
    }

    func testCreateSavesAGroupWithRedactionOnAndNoPin() throws {
        let g = try GroupStore.create(named: "  Weekly team  ", in: dir)
        XCTAssertEqual(g.name, "Weekly team")
        XCTAssertTrue(g.redactContext)
        XCTAssertNil(g.scenario)
        XCTAssertEqual(g.members, [])
        XCTAssertEqual(try GroupStore.load(in: dir), [g])
        XCTAssertTrue(exists("groups.json"))
    }

    func testDuplicateNamesAreRefusedWithoutCaseAndLeaveTheFileAlone() throws {
        try GroupStore.create(named: "Weekly team", in: dir)
        let before = try groupsFileBytes()
        for dup in ["weekly team", "WEEKLY TEAM", " Weekly Team "] {
            XCTAssertThrowsError(try GroupStore.create(named: dup, in: dir), dup) {
                guard case GroupError.nameTaken = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertEqual(try groupsFileBytes(), before)
        XCTAssertEqual(try GroupStore.load(in: dir).count, 1)
    }

    func testEmptyAndTooLongNamesAreRefused() throws {
        for bad in ["", "   ", "\n", "\u{07}\u{08}", String(repeating: "x", count: GroupStore.maxName + 1)] {
            XCTAssertThrowsError(try GroupStore.create(named: bad, in: dir), "\(bad.prefix(10))") {
                XCTAssertEqual($0 as? GroupError, .badName)
            }
        }
        XCTAssertFalse(exists("groups.json"), "nothing written for a refused name")
        XCTAssertNoThrow(try GroupStore.create(named: String(repeating: "x", count: GroupStore.maxName), in: dir))
    }

    func testControlCharactersAndNewlinesInANameAreTakenOut() throws {
        let g = try GroupStore.create(named: "Wee\u{07}kly\nteam\u{1B}[2J", in: dir)
        XCTAssertFalse(g.name.contains("\n"))
        XCTAssertFalse(g.name.contains("\u{07}"))
        XCTAssertFalse(g.name.contains("\u{1B}"))
        XCTAssertEqual(g.name, "Weekly team[2J")
    }

    // MARK: rename

    func testRenameChangesTheNameAndKeepsMembersAndId() throws {
        let g = try makeGroup(["meeting_a"], name: "Old name")
        try GroupStore.rename(g.id, to: "New name", in: dir)
        let after = try XCTUnwrap(try GroupStore.load(in: dir).first)
        XCTAssertEqual(after.name, "New name")
        XCTAssertEqual(after.id, g.id)
        XCTAssertEqual(after.members, ["meeting_a"])
    }

    func testRenameToAnotherGroupsNameIsRefusedButToItsOwnNameInOtherCaseIsFine() throws {
        let a = try GroupStore.create(named: "Alpha", in: dir)
        try GroupStore.create(named: "Beta", in: dir)
        XCTAssertThrowsError(try GroupStore.rename(a.id, to: "bETA", in: dir)) {
            guard case GroupError.nameTaken = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertNoThrow(try GroupStore.rename(a.id, to: "ALPHA", in: dir))
        XCTAssertEqual(try GroupStore.load(in: dir).first?.name, "ALPHA")
    }

    func testRenameRefusesBadNamesAndUnknownGroups() throws {
        let a = try GroupStore.create(named: "Alpha", in: dir)
        XCTAssertThrowsError(try GroupStore.rename(a.id, to: "", in: dir)) {
            XCTAssertEqual($0 as? GroupError, .badName)
        }
        XCTAssertThrowsError(try GroupStore.rename("nope", to: "X", in: dir)) {
            XCTAssertEqual($0 as? GroupError, .noSuchGroup)
        }
        XCTAssertEqual(try GroupStore.load(in: dir).first?.name, "Alpha")
    }

    // MARK: delete keeps the reports

    func testDeletingAGroupKeepsEveryFileOfItsReports() throws {
        try makeRecording()
        let g = try makeGroup([recName])
        let before = try names()
        try GroupStore.delete(g.id, in: dir)
        XCTAssertEqual(try GroupStore.load(in: dir), [])
        XCTAssertNil(GroupStore.group(of: recName, in: dir))
        XCTAssertEqual(Set(try names()).subtracting(["groups.json"]), Set(before).subtracting(["groups.json"]))
        XCTAssertTrue(exists(recName + ".report.json"))
        XCTAssertTrue(exists(recName + ".txt"))
    }

    func testDeletingAnUnknownGroupThrows() throws {
        try GroupStore.create(named: "A", in: dir)
        XCTAssertThrowsError(try GroupStore.delete("nope", in: dir)) { XCTAssertEqual($0 as? GroupError, .noSuchGroup) }
    }

    // MARK: membership

    func testAddingAReportToAnotherGroupMovesIt() throws {
        let a = try GroupStore.create(named: "A", in: dir)
        let b = try GroupStore.create(named: "B", in: dir)
        try GroupStore.add("meeting_x", to: a.id, in: dir)
        try GroupStore.add("meeting_y", to: a.id, in: dir)
        try GroupStore.add("meeting_x", to: b.id, in: dir)
        let groups = try GroupStore.load(in: dir)
        XCTAssertEqual(groups.first { $0.id == a.id }?.members, ["meeting_y"])
        XCTAssertEqual(groups.first { $0.id == b.id }?.members, ["meeting_x"])
        XCTAssertEqual(GroupStore.group(of: "meeting_x", in: dir)?.id, b.id)
    }

    func testAddingTwiceKeepsOneEntry() throws {
        let a = try GroupStore.create(named: "A", in: dir)
        try GroupStore.add("meeting_x", to: a.id, in: dir)
        try GroupStore.add("meeting_x", to: a.id, in: dir)
        XCTAssertEqual(try GroupStore.load(in: dir).first?.members, ["meeting_x"])
    }

    func testAddRefusesPathLikeNamesAndJSONFilesAndUnknownGroups() throws {
        let a = try GroupStore.create(named: "A", in: dir)
        for bad in ["", "../x", "a/b", "..", "meeting.json", "x\u{0}y"] {
            XCTAssertThrowsError(try GroupStore.add(bad, to: a.id, in: dir), bad) {
                XCTAssertEqual($0 as? GroupError, .badMember)
            }
        }
        XCTAssertThrowsError(try GroupStore.add("meeting_x", to: "nope", in: dir)) {
            XCTAssertEqual($0 as? GroupError, .noSuchGroup)
        }
        XCTAssertEqual(try GroupStore.load(in: dir).first?.members, [])
    }

    func testRemoveEverywhereTakesTheReportOutAndLeavesOthersAlone() throws {
        let a = try GroupStore.create(named: "A", in: dir)
        try GroupStore.add("meeting_x", to: a.id, in: dir)
        try GroupStore.add("meeting_y", to: a.id, in: dir)
        try GroupStore.removeEverywhere("meeting_x", in: dir)
        XCTAssertEqual(try GroupStore.load(in: dir).first?.members, ["meeting_y"])
    }

    func testRemoveEverywhereOfAnUngroupedReportWritesNothing() throws {
        try GroupStore.removeEverywhere("meeting_x", in: dir)
        XCTAssertFalse(exists("groups.json"), "no file made for nothing")
        let a = try GroupStore.create(named: "A", in: dir)
        _ = a
        let before = try groupsFileBytes()
        try GroupStore.removeEverywhere("meeting_x", in: dir)
        XCTAssertEqual(try groupsFileBytes(), before)
    }

    func testMembersAreStoredByBaseNameNotPath() throws {
        let g = try GroupStore.create(named: "A", in: dir)
        try GroupStore.add("meeting_x", to: g.id, in: dir)
        let text = String(decoding: try groupsFileBytes(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"meeting_x\""))
        XCTAssertFalse(text.contains(dir.path), "no path in groups.json, so a moved folder still works")
    }

    // MARK: unreadable and newer files

    func testAnUnreadableFileThrowsOnEveryChangeAndStaysByteIdentical() throws {
        let junk = Data("{ this is not json".utf8)
        try junk.write(to: GroupStore.url(in: dir))
        XCTAssertThrowsError(try GroupStore.load(in: dir)) { XCTAssertEqual($0 as? GroupError, .unreadable) }
        XCTAssertNil(GroupStore.group(of: "x", in: dir), "reads as no group, so a report is still written")
        XCTAssertThrowsError(try GroupStore.create(named: "A", in: dir)) {
            XCTAssertEqual($0 as? GroupError, .unreadable)
        }
        XCTAssertThrowsError(try GroupStore.add("x", to: "id", in: dir))
        XCTAssertThrowsError(try GroupStore.rename("id", to: "B", in: dir))
        XCTAssertThrowsError(try GroupStore.delete("id", in: dir))
        XCTAssertThrowsError(try GroupStore.setRedactContext("id", false, globalRedaction: true, in: dir))
        XCTAssertEqual(try groupsFileBytes(), junk)
    }

    func testRemoveEverywhereOnAnUnreadableFileLeavesItAlone() throws {
        let junk = Data("[]".utf8)
        try junk.write(to: GroupStore.url(in: dir))
        XCTAssertNoThrow(try GroupStore.removeEverywhere("x", in: dir))
        XCTAssertEqual(try groupsFileBytes(), junk)
    }

    func testAFileFromANewerVersionIsRefusedAndLeftByteIdentical() throws {
        let newer = Data(#"{"version": 2, "groups": [], "futureField": true}"#.utf8)
        try newer.write(to: GroupStore.url(in: dir))
        XCTAssertThrowsError(try GroupStore.load(in: dir)) { XCTAssertEqual($0 as? GroupError, .newerFile) }
        XCTAssertThrowsError(try GroupStore.create(named: "A", in: dir)) {
            XCTAssertEqual($0 as? GroupError, .newerFile)
        }
        XCTAssertEqual(try groupsFileBytes(), newer)
    }

    func testAMemberlessOldGroupDecodesWithDefaults() throws {
        try Data(#"{"version": 1, "groups": [{"id": "g1", "name": "Old"}]}"#.utf8).write(to: GroupStore.url(in: dir))
        let g = try XCTUnwrap(try GroupStore.load(in: dir).first)
        XCTAssertEqual(g.members, [])
        XCTAssertTrue(g.redactContext, "on unless the file says otherwise")
        XCTAssertNil(g.scenario)
    }

    // MARK: the redaction switch

    func testTheSwitchCanBeTurnedOffAndBackOnWhileGlobalRedactionIsOn() throws {
        let g = try GroupStore.create(named: "A", in: dir)
        try GroupStore.setRedactContext(g.id, false, globalRedaction: true, in: dir)
        XCTAssertEqual(try GroupStore.load(in: dir).first?.redactContext, false)
        try GroupStore.setRedactContext(g.id, true, globalRedaction: true, in: dir)
        XCTAssertEqual(try GroupStore.load(in: dir).first?.redactContext, true)
    }

    func testAGroupCannotTurnItsSwitchOnWhileGlobalRedactionIsOff() throws {
        let g = try GroupStore.create(named: "A", in: dir)
        try GroupStore.setRedactContext(g.id, false, globalRedaction: false, in: dir)
        XCTAssertThrowsError(try GroupStore.setRedactContext(g.id, true, globalRedaction: false, in: dir)) {
            XCTAssertEqual($0 as? GroupError, .redactionOffGlobally)
        }
        XCTAssertEqual(try GroupStore.load(in: dir).first?.redactContext, false, "unchanged by the refused call")
    }

    func testTheSwitchOnAnUnknownGroupThrows() throws {
        XCTAssertThrowsError(try GroupStore.setRedactContext("nope", false, globalRedaction: true, in: dir)) {
            XCTAssertEqual($0 as? GroupError, .noSuchGroup)
        }
    }

    // MARK: the pinned scenario

    func testPinningAnUnknownScenarioIsRefusedAndKnownOnesAreStoredLowercase() throws {
        let g = try GroupStore.create(named: "A", in: dir)
        XCTAssertThrowsError(try GroupStore.setScenario(g.id, "no_such_scenario", catalog: .builtIn, in: dir)) {
            XCTAssertEqual($0 as? GroupError, .unknownScenario("no_such_scenario"))
        }
        XCTAssertNil(try GroupStore.load(in: dir).first?.scenario)
        try GroupStore.setScenario(g.id, "THERAPY", catalog: .builtIn, in: dir)
        XCTAssertEqual(try GroupStore.load(in: dir).first?.scenario, "therapy")
        try GroupStore.setScenario(g.id, nil, catalog: .builtIn, in: dir)
        XCTAssertNil(try GroupStore.load(in: dir).first?.scenario, "nil unpins it")
    }

    func testPinningOnAnUnknownGroupThrows() throws {
        XCTAssertThrowsError(try GroupStore.setScenario("nope", "meeting", catalog: .builtIn, in: dir)) {
            XCTAssertEqual($0 as? GroupError, .noSuchGroup)
        }
    }

    // MARK: delete to the Trash takes the base out of its group (D-94)

    private func trashRemover() -> Notebook.Remover {
        { try FileManager.default.removeItem(at: $0) }  // inside the temp folder; never the real Trash
    }

    func testMovingARecordingToTheTrashRemovesItFromItsGroupButNotASimilarlyNamedOne() throws {
        try makeFullRecording()
        let similar = recName + "x"
        try addRecording(similar, hoursAgo: 5, report: simpleReport(topic: "Similar"))
        let g = try makeGroup([recName, similar])
        try Notebook.trash(base: base, remover: trashRemover())
        XCTAssertFalse(exists(recName + ".report.json"))
        let after = try XCTUnwrap(try GroupStore.load(in: dir).first { $0.id == g.id })
        XCTAssertEqual(after.members, [similar], "only the deleted base left the group")
        XCTAssertTrue(exists(similar + ".report.json"), "the similar one's files stay")
    }

    func testTrashingAnUngroupedRecordingNeverCreatesGroupsJSON() throws {
        try makeFullRecording()
        try Notebook.trash(base: base, remover: trashRemover())
        XCTAssertFalse(exists("groups.json"))
    }

    func testTrashingWithAnUnreadableGroupsFileStillWorksAndLeavesTheFile() throws {
        try makeFullRecording()
        let junk = Data("not json".utf8)
        try junk.write(to: GroupStore.url(in: dir))
        XCTAssertNoThrow(try Notebook.trash(base: base, remover: trashRemover()))
        XCTAssertEqual(try groupsFileBytes(), junk)
    }

    func testARecordingThatStaysAfterAFailedMoveStaysInItsGroup() throws {
        try makeFullRecording()
        let g = try makeGroup([recName])
        let failing: Notebook.Remover = { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try Notebook.trash(base: base, remover: failing))
        XCTAssertEqual(try GroupStore.load(in: dir).first { $0.id == g.id }?.members, [recName])
    }
}
