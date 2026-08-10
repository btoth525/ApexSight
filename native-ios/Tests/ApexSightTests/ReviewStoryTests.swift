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

    // MARK: - Regression: the decode failure that blanked the Review tab

    @Test("other_concerns as an ARRAY decodes — this exact shape emptied the Review tab")
    func otherConcernsArrayDecodes() throws {
        // Modelled as String? from a sample where it was null. Once the feature produced real
        // data Frigate sent an array, the type mismatch threw, and the throw propagated up
        // through ReviewData and FrigateReviewItem — taking the WHOLE review list with it.
        let review = try decodeReview("""
        {"id":"1.0-e","camera":"Front_Driveway","start_time":1.0,"severity":"alert",
         "has_been_reviewed":false,
         "data":{"objects":["person"],
           "metadata":{"title":"Person at the driveway","shortSummary":"Someone approached a car.",
             "other_concerns":["A person looking into vehicles"],
             "potential_threat_level":1,"confidence":0.8}}}
        """)
        let m = try #require(review.data?.metadata)
        #expect(m.otherConcerns == ["A person looking into vehicles"])
        #expect(m.potentialThreatLevel == 1)
    }

    @Test("A bare string for other_concerns is still accepted")
    func otherConcernsStringDecodes() throws {
        let review = try decodeReview("""
        {"id":"1.0-f","camera":"doorbell","start_time":1.0,"severity":"alert",
         "has_been_reviewed":false,
         "data":{"metadata":{"title":"T","other_concerns":"Trying door handles"}}}
        """)
        #expect(review.data?.metadata?.otherConcerns == ["Trying door handles"])
    }

    @Test("A wrong-typed FIELD degrades to nil instead of failing the review")
    func badFieldDegrades() throws {
        let review = try decodeReview("""
        {"id":"1.0-g","camera":"doorbell","start_time":1.0,"severity":"alert",
         "has_been_reviewed":false,
         "data":{"objects":["person"],
           "metadata":{"title":"Still here","potential_threat_level":"high",
             "confidence":"very","observations":"not-a-list"}}}
        """)
        let m = try #require(review.data?.metadata)
        #expect(m.title == "Still here", "the good field survives")
        #expect(m.potentialThreatLevel == nil)
        #expect(m.confidence == nil)
        #expect(m.observations == nil)
        #expect(ThreatLevel(raw: m.potentialThreatLevel) == .routine, "and it fails quiet")
    }

    /// The rating is written by a language model and stored verbatim, so it can come back as `2.0`.
    /// Int-only decoding threw on that and `try?` turned it into nil → routine, silently stripping
    /// the badge off a review the model had flagged. Under-alerting is the direction that matters:
    /// an over-eager badge is noise, a missing one is the thing the user never looks at.
    @Test("A threat level written as a JSON float still rates the review")
    func floatThreatLevelSurvives() throws {
        for (raw, expected) in [("2.0", 2), ("1.0", 1), ("0.0", 0), ("1.6", 2), ("2.4", 2)] {
            let review = try decodeReview("""
            {"id":"1.0-i","camera":"doorbell","start_time":1.0,"severity":"alert",
             "has_been_reviewed":false,
             "data":{"metadata":{"title":"T","potential_threat_level":\(raw)}}}
            """)
            #expect(review.data?.metadata?.potentialThreatLevel == expected,
                    "\(raw) should read as \(expected)")
        }
        // The plain integer path is untouched, and nonsense still fails quiet to routine.
        let exact = try decodeReview("""
        {"id":"1.0-j","camera":"doorbell","start_time":1.0,"severity":"alert",
         "has_been_reviewed":false,"data":{"metadata":{"potential_threat_level":2}}}
        """)
        #expect(ThreatLevel(raw: exact.data?.metadata?.potentialThreatLevel) == .concerning)
    }

    @Test("metadata of an entirely wrong SHAPE can't cost the user their alerts")
    func badShapeStillYieldsReview() throws {
        for bad in ["\"a string\"", "42", "[1,2,3]"] {
            let review = try decodeReview("""
            {"id":"1.0-h","camera":"doorbell","start_time":1.0,"severity":"alert",
             "has_been_reviewed":false,"data":{"objects":["car"],"metadata":\(bad)}}
            """)
            #expect(review.data?.metadata == nil)
            #expect(review.data?.objects == ["car"], "the review itself still decodes")
        }
    }

    @Test("A whole ARRAY of reviews survives one bad member — the actual failure mode")
    func arrayOfReviewsSurvivesOneBadMember() throws {
        // The tab renders a decoded ARRAY. Before the fix, one review with an array-typed
        // other_concerns threw and emptied the entire list.
        let json = """
        [{"id":"a","camera":"doorbell","start_time":1.0,"severity":"alert","has_been_reviewed":false,
          "data":{"objects":["person"]}},
         {"id":"b","camera":"Front_Driveway","start_time":2.0,"severity":"alert","has_been_reviewed":false,
          "data":{"objects":["car"],"metadata":{"title":"T","other_concerns":["x"],"confidence":"bad"}}},
         {"id":"c","camera":"Garage","start_time":3.0,"severity":"alert","has_been_reviewed":false,
          "data":{"objects":["dog"]}}]
        """
        let items = try JSONDecoder().decode([FrigateReviewItem].self, from: Data(json.utf8))
        #expect(items.count == 3, "all three reviews must survive")
        #expect(items[1].data?.metadata?.otherConcerns == ["x"])
    }
    // MARK: - Believing the rating

    /// The real false positive, verbatim from the live server: level 2, "Forced Entry Attempt",
    /// an imagined crowbar — raised against two RECOGNISED RESIDENTS carrying a package, at
    /// confidence 0.02. That is a red, audible, Focus-breaking alarm about a break-in that never
    /// happened, aimed at the family. Every legitimate Level 1 in the same 61-review sample sat at
    /// 0.5-1.0 confidence.
    @Test("A rating the model isn't sure of does not escalate")
    func lowConfidenceDoesNotEscalate() {
        #expect(ThreatLevel.trusted(raw: 2, confidence: 0.02,
                                    objects: ["person-verified", "person-verified"]) == nil)
        #expect(ThreatLevel.trusted(raw: 1, confidence: 0.2, objects: ["person"]) == nil)
        #expect(ThreatLevel.trusted(raw: 2, confidence: nil, objects: ["person"]) == nil)
        #expect(ThreatLevel.trusted(raw: 2, confidence: .nan, objects: ["person"]) == nil)
    }

    /// The other direction is just as important — this must not become a way to go quiet.
    @Test("A confident escalation on an unrecognised person still fires")
    func confidentEscalationSurvives() {
        #expect(ThreatLevel.trusted(raw: 2, confidence: 0.9, objects: ["person"]) == .concerning)
        #expect(ThreatLevel.trusted(raw: 1, confidence: 0.7, objects: ["person"]) == .notable)
        #expect(ThreatLevel.trusted(raw: 1, confidence: ThreatLevel.confidenceFloor,
                                    objects: ["person"]) == .notable)
    }

    /// Frigate labels a face-recognised subject `person-verified`. The rubric already says that is
    /// Level 0 "regardless of time or activity"; the model overrode it, so code enforces it.
    @Test("A recognised resident can't be escalated, however sure the model claims to be")
    func verifiedPersonNeverEscalates() {
        #expect(ThreatLevel.trusted(raw: 2, confidence: 1.0, objects: ["person-verified"]) == nil)
        #expect(ThreatLevel.trusted(raw: 1, confidence: 1.0,
                                    objects: ["car", "person-verified"]) == nil)
    }

    /// Level 0 is exempt: "nothing to see" is the safe answer whatever the confidence, and gating it
    /// would turn every quiet review into an unrated one.
    @Test("Routine is believed unconditionally")
    func routineNeedsNoConfidence() {
        #expect(ThreatLevel.trusted(raw: 0, confidence: 0.01, objects: ["person-verified"]) == .routine)
        #expect(ThreatLevel.trusted(raw: nil, confidence: nil, objects: []) == .routine)
    }

    // MARK: - The summary Frigate cut in half

    /// Frigate hard-clamps `shortSummary` to 140 characters mid-word — 22 of 61 rated reviews on the
    /// live server ended mid-sentence. In all 22, `scene` held the same narrative, finished.
    @Test("The complete sentence wins over Frigate's 140-character clamp")
    func summaryPrefersTheCompleteField() {
        let cut = "An individual is walking towards a parked car on the street. They approach the vehicle but do not enter or interact with it, instead moving "
        let whole = "A person is walking on the street towards a parked car. They approach the car but do not enter or interact with it, instead moving around the front of the house and along the sidewalk."
        let s = ReviewAISummary(title: "T", shortSummary: cut, scene: whole, observations: nil,
                                confidence: 1, potentialThreatLevel: 0, otherConcerns: nil, time: nil)
        #expect(s.summarySentence == whole)
        #expect(s.summarySentence?.hasSuffix("sidewalk.") == true)
    }

    @Test("With nothing complete, the dangling part-word is trimmed and marked")
    func summaryTidiesAnUnavoidableCut() throws {
        // A REAL clamped value: exactly the 140 characters Frigate emits, ending mid-word.
        let cut = "A person approaches the front door of the residence carrying an object, pauses briefly on the porch, and then turns back towards the drivew"
        #expect(cut.count >= ReviewAISummary.clampLength - 1, "must actually look clamped")
        let s = ReviewAISummary(title: nil, shortSummary: cut, scene: nil, observations: nil,
                                confidence: 1, potentialThreatLevel: 0, otherConcerns: nil, time: nil)
        let out = try #require(s.summarySentence)
        #expect(out.hasSuffix("…"))
        #expect(!out.contains("drivew"), "the half-typed word goes with it")
        #expect(out.hasPrefix("A person approaches the front door"))
    }

    /// The guard that stops the tidier vandalising short text: plenty of legitimate summaries
    /// simply lack a full stop, and chopping their last word would be the bug, not the fix.
    @Test("A short summary with no full stop is left exactly as written")
    func shortUnpunctuatedTextIsUntouched() {
        let s = ReviewAISummary(title: nil, shortSummary: "Real text", scene: nil, observations: nil,
                                confidence: nil, potentialThreatLevel: nil, otherConcerns: nil, time: nil)
        #expect(s.summarySentence == "Real text")
        #expect(s.headline == "Real text")
    }

    @Test("A complete shortSummary is kept as-is")
    func completeShortSummaryKept() {
        let s = ReviewAISummary(title: nil, shortSummary: "A car pulled in.", scene: nil,
                                observations: nil, confidence: 1, potentialThreatLevel: 0,
                                otherConcerns: nil, time: nil)
        #expect(s.summarySentence == "A car pulled in.")
    }

    /// A clamped summary must never become the headline — that was a title ending mid-word.
    @Test("The headline falls back to a complete sentence, never a clamped one")
    func headlineNeverEndsMidWord() {
        let cut = String(repeating: "word ", count: 28)
        let s = ReviewAISummary(title: nil, shortSummary: cut, scene: "A car pulled in.",
                                observations: nil, confidence: 1, potentialThreatLevel: 0,
                                otherConcerns: nil, time: nil)
        #expect(s.headline == "A car pulled in.")
    }
}
