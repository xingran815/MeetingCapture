import XCTest

@testable import MeetingCaptureCore

/// M5.2 review D-97 #1: a fact a past report kept from an even earlier one is marked in the
/// context, so it isn't passed forward as that report's own.
final class GroupEarlierMarkTests: GroupTestCase {

    private let mark = "[from an earlier report] "

    private func reportWith(_ items: [Report.Item], section: (String, SectionKind) = ("summary", .bullets)) -> Report {
        var r = simpleReport(topic: "TopicPast")
        r.sections = [Report.Section(id: section.0, title: "Things", kind: section.1, note: nil, items: items)]
        return r
    }

    private func block(_ r: Report) -> String { GroupContextBuilder.render(r, notes: nil, date: now) }

    private func group(_ r: Report) throws -> GroupContext {
        try addRecording("meeting_past", hoursAgo: 5, report: r)
        try addRecording(recName, hoursAgo: 0, report: simpleReport(topic: "Me"))
        try makeGroup([recName, "meeting_past"])
        return try XCTUnwrap(GroupContextBuilder.build(for: base))
    }

    func testM52ReviewD97No1OnlyTheEarlierItemIsMarkedInTheRenderedContext() {
        var carried = Report.Item(text: "CarriedFact one")
        carried.source = "earlier"
        let own = Report.Item(text: "OwnFact two")
        let lines = block(reportWith([carried, own])).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("- \(mark)CarriedFact one"), "\(lines)")
        XCTAssertTrue(lines.contains("- OwnFact two"), "\(lines)")
        XCTAssertEqual(lines.filter { $0.contains(mark) }.count, 1)
    }

    func testM52ReviewD97No1TheMarkIsAfterTheKeyAndBackgroundPriorityMarks() {
        var high = Report.Item(text: "HighCarried")
        high.source = "earlier"
        high.priority = "high"
        var low = Report.Item(text: "LowCarried")
        low.source = "earlier"
        low.priority = "low"
        let lines = block(reportWith([high, low])).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("- [key] \(mark)HighCarried"), "\(lines)")
        XCTAssertTrue(lines.contains("- [background] \(mark)LowCarried"), "\(lines)")
    }

    func testM52ReviewD97No1TheMarkIsCaseInsensitiveLikeTheReportsOwnCheck() {
        var item = Report.Item(text: "ShoutedCarried")
        item.source = "EARLIER"
        XCTAssertTrue(block(reportWith([item])).contains("- \(mark)ShoutedCarried"))
    }

    func testM52ReviewD97No1TheSectionsAndReviewInputsCarryTheMarkAfterTheHeading() async throws {
        var carried = Report.Item(text: "CarriedFact one")
        carried.source = "earlier"
        let context = try group(reportWith([carried, Report.Item(text: "OwnFact two")]))
        let b = echoBackend()
        _ = try await ReportFixtures.pipeline(b).run(transcript: transcriptText, context: context)
        for tier in [ModelTier.normal, .frontier] {
            let input = try XCTUnwrap(b.calls(tier).first).input
            let h = try XCTUnwrap(input.range(of: SummaryPipeline.contextHeading))
            let after = String(input[h.upperBound...])
            XCTAssertTrue(after.contains("- \(mark)CarriedFact one"), "\(tier): \(after)")
            XCTAssertTrue(after.contains("- OwnFact two"), "\(tier)")
            XCTAssertFalse(input[..<h.lowerBound].contains(mark), "\(tier): not before the heading")
        }
        XCTAssertFalse(try XCTUnwrap(b.calls(.cheap).first).input.contains(mark))
    }

    func testM52ReviewD97No1AnInsightsItemReturnedAsEarlierEndsUpSourceAIWithNoEarlierMarker() async throws {
        let carried = Report.Item(text: "Past fact")
        let context = try group(reportWith([carried]))
        let b = ScriptedBackend(onComplete: { call in
            let item = Replies.item("Try a weekly check-in", source: "earlier")
            switch call.tier {
            case .cheap: return Replies.classify("therapy")
            default: return Replies.sectionsItems(["insights": [item]])
            }
        })
        let outcome = try await ReportFixtures.pipeline(b).run(
            transcript: transcriptText, forcedScenario: "therapy", context: context)
        let insights = items(outcome.report, "insights")
        XCTAssertEqual(insights.count, 1)
        XCTAssertEqual(insights.first?.source, "ai")
        XCTAssertFalse(insights.first?.isEarlier ?? true)
        XCTAssertFalse(ReportRenderer.html(outcome.report).contains("<p class=\"earlier\">"))
        XCTAssertFalse(ReportRenderer.markdown(outcome.report).contains("_(from an earlier report"))
        XCTAssertFalse(ReportConsole.text(outcome.report, showTranscript: false).contains("[earlier report]"))
    }
}
