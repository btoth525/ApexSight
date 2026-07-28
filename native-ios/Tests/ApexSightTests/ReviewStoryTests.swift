import Foundation
import Testing
@testable import ApexSightNative

/// Guards for Frigate 0.18's review-level GenAI story (`review.data.metadata`).
///
/// Two things must hold. First, the summary is produced by a language model and older reviews have
/// none at all — so a missing or partial record must degrade to "show what we have", never fail the
/// whole review's decode and blank the Review tab. Second, the threat rating must FAIL QUIET: an
/// absent or unexpected level renders as routine, because a decode hiccup must not raise an alarm.
@Suite("Review AI story")
struct ReviewStoryTests {

    private func decodeReview(_ json: String) throws -> FrigateReviewItem {
        try JSONDecoder().decode(FrigateReviewItem.self, from: Data(json.utf8))
    }

    // MARK: - Decoding

    @Test("Decodes a full summary from Frigate's real payload shape")
    func decodesRealPayload() throws {
        // Field names and nesting copied from a live review on the user's Frigate.
        let review = try decodeReview("""
        {"id":"1.0-a","camera":"doorbell","start_time":1.0,"end_time":2.0,"severity":"alert",
         "has_been_reviewed":false,
         "data":{"objects":["person"],"detections":["1.0-x"],
           "metadata":{"title":"Daytime Package Delivery at Residence",
             "shortSummary":"A person delivers multiple packages.",
             "scene":"A person approaches carrying packages...",
             "observations":["Approaches from the right.","Places packages on the porch."],
             "confidence":1.0,"potential_threat_level":0,"other_concerns":null,
             "time":"Monday, 01:28 PM"}}}
        """)
        let m = try #require(review.data?.metadata)
        #expect(m.title == "Daytime Package Delivery at Residence")
        #expect(m.shortSummary == "A person delivers multiple packages.")
        #expect(m.observations?.count == 2)
        #expect(m.confidence == 1.0)
        #expect(m.potentialThreatLevel == 0)
        #expect(m.otherConcerns == nil)
        #expect(m.time == "Monday, 01:28 PM")
        #expect(m.hasContent)
    }

    @Test("A review with NO metadata still decodes — most reviews predate the feature")
    func decodesWithoutMetadata() throws {
        let review = try decodeReview("""
        {"id":"1.0-b","camera":"doorbell","start_time":1.0,"severity":"alert",
         "has_been_reviewed":false,"data":{"objects":["car"],"detections":[]}}
        """)
        #expect(review.data?.metadata == nil)
    }

    @Test("A partial summary decodes rather than failing the whole review")
    func decodesPartial() throws {
        let review = try decodeReview("""
        {"id":"1.0-c","camera":"doorbell","start_time":1.0,"severity":"alert",
         "has_been_reviewed":false,
         "data":{"objects":["person"],"metadata":{"shortSummary":"Someone walked past."}}}
        """)
        let m = try #require(review.data?.metadata)
        #expect(m.title == nil)
        #expect(m.hasContent, "a lone shortSummary is still worth rendering")
        #expect(m.headline == "Someone walked past.")
    }

    @Test("An empty summary object reports no content, so no card is drawn")
    func emptySummaryHasNoContent() throws {
        let review = try decodeReview("""
        {"id":"1.0-d","camera":"doorbell","start_time":1.0,"severity":"alert",
         "has_been_reviewed":false,"data":{"metadata":{"confidence":0.4}}}
        """)
        #expect(review.data?.metadata?.hasContent == false)
    }

    @Test("Headline falls through title → shortSummary → scene")
    func headlineFallsThrough() {
        let onlyScene = ReviewAISummary(title: nil, shortSummary: nil, scene: "A car pulls in.",
                                        observations: nil, confidence: nil,
                                        potentialThreatLevel: nil, otherConcerns: nil, time: nil)
        #expect(onlyScene.headline == "A car pulls in.")

        let titled = ReviewAISummary(title: "Delivery", shortSummary: "Short", scene: "Long",
                                     observations: nil, confidence: nil,
                                     potentialThreatLevel: nil, otherConcerns: nil, time: nil)
        #expect(titled.headline == "Delivery")
    }

    @Test("Whitespace-only fields are skipped by the headline")
    func headlineSkipsBlankFields() {
        let s = ReviewAISummary(title: "   ", shortSummary: "\n", scene: "Real text",
                                observations: nil, confidence: nil,
                                potentialThreatLevel: nil, otherConcerns: nil, time: nil)
        #expect(s.headline == "Real text")
    }

    // MARK: - Threat level (fail quiet)

    @Test("Level 0 and nil both read as routine")
    func routineLevels() {
        #expect(ThreatLevel(raw: 0) == .routine)
        #expect(ThreatLevel(raw: nil) == .routine)
    }

    @Test("A negative level fails quiet to routine rather than crashing or alarming")
    func negativeIsRoutine() {
        #expect(ThreatLevel(raw: -5) == .routine)
    }

    @Test("Levels above the top saturate instead of vanishing")
    func highLevelsSaturate() {
        #expect(ThreatLevel(raw: 2) == .concerning)
        #expect(ThreatLevel(raw: 99) == .concerning)
    }

    @Test("Only above-routine activity earns a badge in the list")
    func onlyNotableGetsRowBadge() {
        #expect(!ThreatLevel.routine.deservesRowBadge, "badging every delivery would train you to ignore it")
        #expect(ThreatLevel.notable.deservesRowBadge)
        #expect(ThreatLevel.concerning.deservesRowBadge)
    }

    @Test("Every level has a distinct symbol and label — never colour alone")
    func levelsAreNotColourOnly() {
        let symbols = Set(ThreatLevel.allCases.map(\.symbol))
        let labels = Set(ThreatLevel.allCases.map(\.label))
        #expect(symbols.count == ThreatLevel.allCases.count)
        #expect(labels.count == ThreatLevel.allCases.count)
    }

    @Test("Levels order by severity")
    func levelsAreComparable() {
        #expect(ThreatLevel.routine < ThreatLevel.notable)
        #expect(ThreatLevel.notable < ThreatLevel.concerning)
    }
}
