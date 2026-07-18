import Testing
import Foundation
@testable import ApexSightNative

/// Regression guards for the object↔sub-label attribution bug: Frigate's `objects` and
/// `sub_labels` on a review are independently deduplicated lists, NOT positionally paired.
/// Live production data surfaced reviews where `objects.first` didn't belong to
/// `sub_labels.first` (a person + a verified car whose sub-label was a truck's name rendered
/// "Person — Brandons Truck"). These tests pin the fix: pair only when unambiguous, never
/// invent a false attribution.
@Suite("NotificationCopy attribution")
struct NotificationCopyAttributionTests {
    private func review(
        objects: [String], subLabels: [String] = [], verifiedObjects: [String]? = nil
    ) throws -> FrigateReviewItem {
        var dataDict: [String: Any] = [
            "objects": objects,
            "sub_labels": subLabels,
        ]
        if let verifiedObjects { dataDict["verified_objects"] = verifiedObjects }
        let json: [String: Any] = [
            "id": "review-1",
            "camera": "front_door",
            "start_time": 1_000.0,
            "data": dataDict,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(FrigateReviewItem.self, from: data)
    }

    @Test("Person + verified car does not attribute the truck's name to the person")
    func mixedObjectsDontFalselyPairPerson() throws {
        // The exact live example: objects ["person", "car-verified"], sub_labels ["Brandons_Truck"].
        let r = try review(
            objects: ["person", "car-verified"], subLabels: ["Brandons_Truck"],
            verifiedObjects: ["car-verified"]
        )
        let combined = NotificationCopy.combinedTitle(for: r)
        #expect(!combined.contains("Person — Brandons Truck"))
        #expect(combined.contains("Car — Brandons Truck"))

        let title = NotificationCopy.title(for: r)
        #expect(!title.hasPrefix("🧍 Brandons Truck"))
    }

    @Test("Car + verified person does not attribute a person's name to the car")
    func mixedObjectsDontFalselyPairCar() throws {
        // The exact live example: objects ["car", "person-verified"], sub_labels ["Brandon"].
        let r = try review(
            objects: ["car", "person-verified"], subLabels: ["Brandon"],
            verifiedObjects: ["person-verified"]
        )
        let combined = NotificationCopy.combinedTitle(for: r)
        #expect(!combined.contains("Car — Brandon"))
        #expect(combined.contains("Person — Brandon"))
    }

    @Test("A single object type still pairs confidently even without verified_objects")
    func singleObjectTypeStillPairs() throws {
        let r = try review(objects: ["person"], subLabels: ["Alex"])
        #expect(NotificationCopy.combinedTitle(for: r).contains("Person — Alex"))
        #expect(NotificationCopy.title(for: r).contains("Alex"))
    }

    @Test("Ambiguous multi-object review with no verified_objects claims no pairing")
    func ambiguousWithoutVerifiedClaimsNoPairing() throws {
        let r = try review(objects: ["person", "car"], subLabels: ["Brandons_Truck"])
        let combined = NotificationCopy.combinedTitle(for: r)
        // Both distinct object types are listed together (not a substring check — "Car, Person
        // — Brandons Truck" legitimately contains "Person — Brandons Truck" as a tail, which
        // isn't the bug; the bug is singling out ONE object, e.g. "🧍 Person — Brandons Truck").
        #expect(combined == "🧍 Car, Person — Brandons Truck")
        #expect(!combined.hasPrefix("🧍 Person —"))
        #expect(!combined.hasPrefix("🚗 Car —"))
    }

    @Test("The -verified suffix never leaks into display text or breaks emoji lookup")
    func verifiedSuffixStrippedForDisplay() throws {
        let r = try review(
            objects: ["car-verified"], subLabels: ["Brandons_Truck"], verifiedObjects: ["car-verified"]
        )
        let combined = NotificationCopy.combinedTitle(for: r)
        #expect(!combined.contains("verified"))
        #expect(combined.hasPrefix("🚗"))
    }
}

/// Regression guards for `IncidentBuilder`: clustering must not fabricate cross-camera
/// "stories" out of merely-simultaneous, unrelated activity on different cameras.
@Suite("Incident clustering")
struct IncidentBuilderCameraScopeTests {
    private func event(
        id: String, camera: String, label: String, subLabel: String? = nil, start: Double
    ) throws -> FrigateEvent {
        var json: [String: Any] = [
            "id": id, "camera": camera, "label": label,
            "start_time": start, "end_time": start + 5,
        ]
        if let subLabel { json["sub_label"] = subLabel }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(FrigateEvent.self, from: data)
    }

    @Test("Unrelated cameras within the time gap do not merge into one incident")
    func unrelatedCamerasDontMerge() throws {
        let e1 = try event(id: "1-abc", camera: "driveway", label: "car", start: 1_000)
        let e2 = try event(id: "2-abc", camera: "backyard", label: "cat", start: 1_050)
        let incidents = IncidentBuilder.build(from: [e1, e2], gap: 120)
        #expect(incidents.count == 2)
    }

    @Test("A burst of activity on the same camera still clusters into one incident")
    func sameCameraStillClusters() throws {
        let e1 = try event(id: "1-abc", camera: "driveway", label: "car", start: 1_000)
        let e2 = try event(id: "2-abc", camera: "driveway", label: "person", start: 1_050)
        let incidents = IncidentBuilder.build(from: [e1, e2], gap: 120)
        #expect(incidents.count == 1)
    }

    @Test("A shared sub-label still links genuine cross-camera movement")
    func sharedSubLabelLinksCameras() throws {
        let e1 = try event(id: "1-abc", camera: "driveway", label: "person", subLabel: "Brandon", start: 1_000)
        let e2 = try event(id: "2-abc", camera: "front_door", label: "person", subLabel: "Brandon", start: 1_050)
        let incidents = IncidentBuilder.build(from: [e1, e2], gap: 120)
        #expect(incidents.count == 1)
    }
}
