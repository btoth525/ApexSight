import Foundation
import Testing
@testable import ApexSightNative

/// Frigate puts the recognized license plate in two different places depending on the transport:
/// the WebSocket tracked-object frame carries it at TOP level, while the REST `/api/events`
/// response carries it only under `data`. The decoder read the top level only, so every
/// REST-fetched event had a nil plate — the Explore plate filter matched nothing, the purple plate
/// chip never drew, and Spotlight indexed no plates. Measured against the live Frigate 0.18 at
/// 192.168.1.204:5000: 300 `/api/events` rows plus event `1786200060.753089-jego7p`
/// (`data.recognized_license_plate = "VZL-2870"`, score 0.99) — never top-level.
///
/// These pin BOTH shapes, because a server that does send it top-level must keep working.
@Suite("Event license plate decoding")
struct EventPlateDecodeTests {

    private func decode(_ json: String) throws -> FrigateEvent {
        try JSONDecoder().decode(FrigateEvent.self, from: Data(json.utf8))
    }

    @Test("The REST shape — plate nested under data — is what production actually sends")
    func nestedPlateDecodes() throws {
        let event = try decode("""
        {"id":"1786200060.753089-jego7p","camera":"Front_Driveway","label":"car",
         "data":{"recognized_license_plate":"VZL-2870","recognized_license_plate_score":0.9888}}
        """)
        #expect(event.recognizedLicensePlate == "VZL-2870")
        #expect(event.recognizedLicensePlateScore == 0.9888)
    }

    @Test("The WebSocket shape — plate at top level — still decodes")
    func topLevelPlateDecodes() throws {
        let event = try decode("""
        {"id":"1.2-a","camera":"Front_Driveway","label":"car",
         "recognized_license_plate":"ABC-1234","recognized_license_plate_score":0.77}
        """)
        #expect(event.recognizedLicensePlate == "ABC-1234")
        #expect(event.recognizedLicensePlateScore == 0.77)
    }

    @Test("Top level wins when both are present, so a fresher WS value isn't shadowed")
    func topLevelPreferred() throws {
        let event = try decode("""
        {"id":"1.2-a","camera":"Front_Driveway","label":"car",
         "recognized_license_plate":"NEW-111",
         "data":{"recognized_license_plate":"OLD-999"}}
        """)
        #expect(event.recognizedLicensePlate == "NEW-111")
    }

    @Test("An empty top-level plate falls through to the nested one instead of blanking it")
    func emptyTopLevelFallsThrough() throws {
        let event = try decode("""
        {"id":"1.2-a","camera":"Front_Driveway","label":"car",
         "recognized_license_plate":"",
         "data":{"recognized_license_plate":"VZL-2870"}}
        """)
        #expect(event.recognizedLicensePlate == "VZL-2870")
    }

    @Test("No plate anywhere stays nil — the row must not show an empty plate chip")
    func noPlateStaysNil() throws {
        let none = try decode("""
        {"id":"1.2-a","camera":"Front_Driveway","label":"car","data":{"score":0.8}}
        """)
        #expect(none.recognizedLicensePlate == nil)
        #expect(none.recognizedLicensePlateScore == nil)

        let blank = try decode("""
        {"id":"1.2-a","camera":"Front_Driveway","label":"car",
         "data":{"recognized_license_plate":""}}
        """)
        #expect(blank.recognizedLicensePlate == nil)
    }

    @Test("A wrong-typed plate can't fail the event — one bad row must not empty the feed")
    func wrongTypeDegradesToNil() throws {
        let event = try decode("""
        {"id":"1.2-a","camera":"Front_Driveway","label":"car",
         "data":{"recognized_license_plate":[1,2],"recognized_license_plate_score":"high"}}
        """)
        #expect(event.recognizedLicensePlate == nil)
        #expect(event.recognizedLicensePlateScore == nil)
        #expect(event.camera == "Front_Driveway")
    }
}
