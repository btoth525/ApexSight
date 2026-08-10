import Foundation
import Testing
@testable import ApexSightNative

/// `/api/review` is decoded as one atomic `[FrigateReviewItem]`, and `AppState.refresh()` wraps
/// that in `try?` and keeps the previous value on failure — empty on a cold start. So ONE review
/// with one surprising field used to blank the whole Review tab and read the badge as 0 while
/// alerts piled up on the server. That exact regression already shipped once (`other_concerns`),
/// and the fix then only hardened `metadata`.
///
/// These pin the two remaining layers: a wrong-typed field inside `data`, and `data` itself
/// arriving in a shape ReviewData's decoder can't even enter.
@Suite("Review lenient decoding")
struct ReviewLenientDecodeTests {

    private func decodeArray(_ json: String) throws -> [FrigateReviewItem] {
        try JSONDecoder().decode([FrigateReviewItem].self, from: Data(json.utf8))
    }

    @Test("The real payload shape still decodes exactly as before")
    func realShapeUnchanged() throws {
        let items = try decodeArray("""
        [{"id":"1786.5-abc","camera":"Front_Driveway","start_time":1786.5,"end_time":1800.0,
          "severity":"alert","thumb_path":"/media/x.webp","has_been_reviewed":false,
          "data":{"detections":["1.2-a"],"objects":["person"],"sub_labels":["Brandon"],
                  "zones":["front_yard"],"audio":[],"thumb_time":1790.0,
                  "verified_objects":["person"]}}]
        """)
        #expect(items.count == 1)
        #expect(items[0].camera == "Front_Driveway")
        #expect(items[0].severity == "alert")
        #expect(items[0].data?.subLabels == ["Brandon"])
        #expect(items[0].data?.thumbTime == 1790.0)
    }

    @Test("A future sub_labels shape degrades that field to nil instead of emptying the tab")
    func wrongTypedSubLabelsSurvives() throws {
        let items = try decodeArray("""
        [{"id":"1.2-a","camera":"Side_Gate",
          "data":{"objects":["car"],"sub_labels":[["Brandon",0.98]]}}]
        """)
        #expect(items.count == 1)
        #expect(items[0].data?.subLabels == nil)
        #expect(items[0].data?.objects == ["car"])
    }

    @Test("Every other data field is isolated too, not just metadata")
    func eachDataFieldIsolated() throws {
        let items = try decodeArray("""
        [{"id":"1.2-a","camera":"Garage",
          "data":{"detections":"not-a-list","objects":7,"zones":{"a":1},
                  "audio":false,"thumb_time":"soon","verified_objects":[[]],
                  "metadata":"not-an-object"}}]
        """)
        #expect(items.count == 1)
        #expect(items[0].camera == "Garage")
        #expect(items[0].data?.detections == nil)
        #expect(items[0].data?.objects == nil)
        #expect(items[0].data?.thumbTime == nil)
        #expect(items[0].data?.metadata == nil)
    }

    @Test("`data` in a wholly wrong SHAPE can't fail the review — ReviewData's own guards can't reach this")
    func wrongShapedDataSurvives() throws {
        for shape in ["[]", "\"nope\"", "42", "true"] {
            let items = try decodeArray("""
            [{"id":"1.2-a","camera":"zachs_room","severity":"detection","data":\(shape)}]
            """)
            #expect(items.count == 1)
            #expect(items[0].data == nil)
            #expect(items[0].severity == "detection")
        }
    }

    @Test("A wrong-typed top-level field degrades rather than dropping the whole array")
    func wrongTypedTopLevelSurvives() throws {
        let items = try decodeArray("""
        [{"id":"1.2-a","camera":"doorbell","start_time":"soon","has_been_reviewed":"yes",
          "severity":3,"thumb_path":[]}]
        """)
        #expect(items.count == 1)
        #expect(items[0].startTime == nil)
        #expect(items[0].hasBeenReviewed == nil)
        #expect(items[0].severity == nil)
    }

    @Test("A whole ARRAY survives one bad member — the actual failure mode")
    func arraySurvivesOneBadMember() throws {
        let items = try decodeArray("""
        [{"id":"a","camera":"Front_Driveway","severity":"alert"},
         {"id":"b","camera":"Side_Gate","data":{"sub_labels":[["x",1]]}},
         {"id":"c","camera":"Garage","severity":"detection"}]
        """)
        #expect(items.map(\.id) == ["a", "b", "c"])
    }

    @Test("id and camera stay required — a review without them is not a review")
    func idAndCameraStillRequired() {
        #expect(throws: (any Error).self) {
            try decodeArray(#"[{"camera":"Front_Driveway"}]"#)
        }
        #expect(throws: (any Error).self) {
            try decodeArray(#"[{"id":"a"}]"#)
        }
    }

    @Test("The memberwise initializer still exists for the debug/test fixtures that use it")
    func memberwiseInitPreserved() {
        let item = FrigateReviewItem(
            id: "x", camera: "Garage", startTime: 1, endTime: 2, severity: "alert",
            thumbPath: nil, hasBeenReviewed: false, data: nil, description: "hi"
        )
        #expect(item.description == "hi")
    }
}
