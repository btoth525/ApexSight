import Foundation
import CoreGraphics

struct FrigateSession: Codable, Equatable {
    let baseURL: URL
    let username: String
    let token: String
    /// Retained in the device-only Keychain so the app can silently refresh the
    /// `frigate_token` JWT on a 401 (e.g. mid-stream token expiry) by re-running the
    /// existing login. Optional so previously-stored sessions still decode.
    let password: String?
    /// Optional home-network URL for the *same* Frigate (e.g. `http://192.168.1.204:5000`).
    /// When set and currently reachable, the app talks to Frigate directly over the LAN —
    /// fast, no reverse-proxy/tunnel hop — and falls back to `baseURL` (the remote URL) when
    /// away from home. Same server ⇒ the same JWT works for both hosts, so switching needs no
    /// re-auth. Optional so previously-stored sessions still decode (defaults to nil = remote-only).
    let localBaseURL: URL?

    init(baseURL: URL, username: String, token: String, password: String? = nil, localBaseURL: URL? = nil) {
        self.baseURL = baseURL
        self.username = username
        self.token = token
        self.password = password
        self.localBaseURL = localBaseURL
    }

    static func normalizedBaseURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FrigateError.invalidURL }

        // Host without any `:port` suffix, so local-host detection works whether or not the
        // user typed a port (e.g. `frigate.local:8971`, `localhost:5000`).
        let hostOnly = String(trimmed.split(separator: ":", maxSplits: 1).first ?? "")
        let lowerHost = hostOnly.lowercased()

        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else if hostOnly.hasPrefix("192.168.") || hostOnly.hasPrefix("10.") || hostOnly.hasPrefix("127.") || lowerHost == "localhost" || lowerHost.hasSuffix(".local") || isLAN172(host: hostOnly) {
            // LAN / loopback / mDNS hosts speak plain HTTP by default (no public TLS cert).
            withScheme = "http://\(trimmed)"
        } else {
            withScheme = "https://\(trimmed)"
        }

        guard let url = URL(string: withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            throw FrigateError.invalidURL
        }
        return url
    }

    private static func isLAN172(host: String) -> Bool {
        let parts = host.split(separator: ".", maxSplits: 2)
        guard parts.count >= 2,
              parts[0] == "172",
              let second = Int(parts[1]),
              second >= 16, second <= 31 else { return false }
        return true
    }
}

struct FrigateCamera: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    let zones: [String]
    let objects: [String]
    /// Native detect resolution from Frigate config — drives per-camera tile aspect so
    /// fisheye / ultra-wide feeds aren't letterboxed into a forced 16:9 box.
    var width: Int? = nil
    var height: Int? = nil

    /// The camera's true aspect, falling back to 16:9 when Frigate didn't report dimensions.
    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 16.0 / 9.0 }
        return CGFloat(width) / CGFloat(height)
    }
}

/// A single point on a tracked object's movement trail (`data.path_data`). Normalized 0-1 to the
/// full detect frame, top-left origin, y-down — the same space `snapshot.jpg` fills and the same
/// convention SwiftUI uses, so overlays map with a bare multiply (no y-flip).
struct PathPoint: Hashable { let x, y: Double; let ts: Double }

/// One beat in a tracked object's lifecycle (Frigate `/api/timeline`): detected, entered a zone,
/// recognized an attribute, went stationary/active, left. `box` is normalized [x,y,w,h].
struct TimelineBeat: Identifiable, Decodable, Hashable {
    let id = UUID()
    let ts: Double
    let classType: String
    let box: CGRect?
    let score: Double?
    let zones: [String]?
    let attribute: String?
    let subLabel: String?

    private enum CK: String, CodingKey { case ts = "timestamp", classType = "class_type", data }
    private enum DK: String, CodingKey { case box, score, zones, attribute, subLabel = "sub_label" }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CK.self)
        ts = (try? c.decode(Double.self, forKey: .ts)) ?? 0
        classType = (try? c.decode(String.self, forKey: .classType)) ?? "unknown"
        let dc = try? c.nestedContainer(keyedBy: DK.self, forKey: .data)
        score = (try? dc?.decodeIfPresent(Double.self, forKey: .score)) ?? nil
        zones = (try? dc?.decodeIfPresent([String].self, forKey: .zones)) ?? nil
        attribute = (try? dc?.decodeIfPresent(String.self, forKey: .attribute)) ?? nil
        if let arr = (try? dc?.decodeIfPresent([Double].self, forKey: .box)) ?? nil, arr.count == 4 {
            box = CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
        } else { box = nil }
        // sub_label is polymorphic: null | "name" | ["name", 0.77] — never let it throw.
        if let str = (try? dc?.decodeIfPresent(String.self, forKey: .subLabel)) ?? nil {
            subLabel = str
        } else if var u = try? dc?.nestedUnkeyedContainer(forKey: .subLabel), let str = try? u.decode(String.self) {
            subLabel = str
        } else { subLabel = nil }
    }
    static func == (a: TimelineBeat, b: TimelineBeat) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct FrigateEvent: Identifiable, Codable, Hashable {
    let id: String
    let camera: String
    let label: String
    let subLabel: String?
    let subLabelScore: Double?
    let startTime: Double?
    let endTime: Double?
    let score: Double?
    let topScore: Double?
    let zones: [String]?
    let hasClip: Bool?
    let hasSnapshot: Bool?
    let recognizedLicensePlate: String?
    let recognizedLicensePlateScore: Double?
    /// GenAI description (from `data.description`) — present when GenAI descriptions
    /// are enabled, and what Frigate's "description" semantic search matches against.
    let description: String?
    /// Relevance fields returned only by `/api/events/search` (lower distance = better
    /// match). `searchSource` is "thumbnail" or "description".
    let searchDistance: Double?
    let searchSource: String?
    /// The moment (`data.snapshot_frame_time`) the object's snapshot was captured. Frigate
    /// re-chooses this frame for as long as the track lives, so on a long-lived object it can
    /// sit far outside the review that referenced it — see `ReviewStillPolicy`.
    let snapshotFrameTime: Double?
    /// Bounding box in pixels [x1, y1, x2, y2] from the WebSocket event stream.
    /// Pair with `frameWidth`/`frameHeight` to get 0-1 normalized overlay coords.
    let box: [Double]?
    let frameWidth: Double?
    let frameHeight: Double?
    /// The object's movement trail (`data.path_data`), oldest→newest. Normalized 0-1 to the full frame.
    let pathData: [PathPoint]?
    /// `data.box` — the object box NORMALIZED as [x,y,w,h] (top-left+size). Distinct from the pixel
    /// `[x1,y1,x2,y2]` top-level `box` above; never run this through the pixel box helper.
    let normBox: CGRect?
    /// `data.region` — the detect region NORMALIZED [x,y,w,h] (h can exceed 1.0).
    let region: CGRect?

    var displayLabel: String {
        if let sub = subLabel, !sub.isEmpty { return sub }
        return label
    }

    /// A recognized face is surfaced by Frigate as the sub_label on a person event.
    var recognizedFace: String? {
        guard label.lowercased() == "person", let sub = subLabel, !sub.isEmpty else { return nil }
        return sub
    }

    enum CodingKeys: String, CodingKey {
        case id
        case camera
        case label
        case subLabel = "sub_label"
        case subLabelScore = "sub_label_score"
        case startTime = "start_time"
        case endTime = "end_time"
        case score
        case topScore = "top_score"
        case zones
        case hasClip = "has_clip"
        case hasSnapshot = "has_snapshot"
        case recognizedLicensePlate = "recognized_license_plate"
        case recognizedLicensePlateScore = "recognized_license_plate_score"
        case description
        case searchDistance = "search_distance"
        case searchSource = "search_source"
        case snapshotFrameTime = "snapshot_frame_time"
        case box
        case frameWidth = "width"
        case frameHeight = "height"
    }

    /// Accessor for the nested `data` object — kept out of `CodingKeys` so the
    /// synthesized `Encodable` only sees real stored properties.
    private enum DataOuterKeys: String, CodingKey {
        case data
    }

    /// Fields Frigate nests under the event's `data` object.
    private enum DataKeys: String, CodingKey {
        case score
        case topScore = "top_score"
        case description
        case snapshotFrameTime = "snapshot_frame_time"
        case recognizedLicensePlate = "recognized_license_plate"
        case recognizedLicensePlateScore = "recognized_license_plate_score"
        case box
        case region
        case pathData = "path_data"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        camera = try c.decode(String.self, forKey: .camera)
        label = try c.decode(String.self, forKey: .label)
        // sub_label can be String OR [String] in different Frigate versions
        if let arr = try? c.decodeIfPresent([String].self, forKey: .subLabel) {
            subLabel = arr.first
        } else {
            subLabel = try? c.decodeIfPresent(String.self, forKey: .subLabel)
        }
        subLabelScore = try? c.decodeIfPresent(Double.self, forKey: .subLabelScore)
        startTime = try? c.decodeIfPresent(Double.self, forKey: .startTime)
        endTime = try? c.decodeIfPresent(Double.self, forKey: .endTime)
        zones = try? c.decodeIfPresent([String].self, forKey: .zones)
        hasClip = try? c.decodeIfPresent(Bool.self, forKey: .hasClip)
        hasSnapshot = try? c.decodeIfPresent(Bool.self, forKey: .hasSnapshot)
        searchDistance = try? c.decodeIfPresent(Double.self, forKey: .searchDistance)
        searchSource = try? c.decodeIfPresent(String.self, forKey: .searchSource)
        box = try? c.decodeIfPresent([Double].self, forKey: .box)
        frameWidth = try? c.decodeIfPresent(Double.self, forKey: .frameWidth)
        frameHeight = try? c.decodeIfPresent(Double.self, forKey: .frameHeight)

        // score / top_score / description can be top-level OR nested under `data`
        // (the /events/search response nests them) — read both, preferring top-level.
        var dataScore: Double?, dataTopScore: Double?, dataDescription: String?
        var dataSnapshotFrameTime: Double?
        // The REST /api/events response carries the recognized plate ONLY under `data`
        // (measured across 300 rows + a known plate event on Frigate 0.18); the WebSocket
        // tracked-object payload carries it at top level. Read both, preferring top-level.
        var dataPlate: String?, dataPlateScore: Double?
        var dataPathData: [PathPoint]? = nil, dataNormBox: CGRect? = nil, dataRegion: CGRect? = nil
        if let dataOuter = try? decoder.container(keyedBy: DataOuterKeys.self),
           let dataC = try? dataOuter.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
            dataScore = try? dataC.decodeIfPresent(Double.self, forKey: .score)
            dataTopScore = try? dataC.decodeIfPresent(Double.self, forKey: .topScore)
            dataDescription = try? dataC.decodeIfPresent(String.self, forKey: .description)
            dataSnapshotFrameTime = try? dataC.decodeIfPresent(Double.self, forKey: .snapshotFrameTime)
            dataPlate = try? dataC.decodeIfPresent(String.self, forKey: .recognizedLicensePlate)
            dataPlateScore = try? dataC.decodeIfPresent(Double.self, forKey: .recognizedLicensePlateScore)
            if let b = try? dataC.decodeIfPresent([Double].self, forKey: .box), b.count == 4 {
                dataNormBox = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
            }
            if let r = try? dataC.decodeIfPresent([Double].self, forKey: .region), r.count == 4 {
                dataRegion = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
            }
            var pts: [PathPoint] = []
            if var outer = try? dataC.nestedUnkeyedContainer(forKey: .pathData) {
                var guardN = 0
                while !outer.isAtEnd && guardN < 5000 {
                    guardN += 1
                    guard var entry = try? outer.nestedUnkeyedContainer() else {
                        _ = try? outer.decode(Double.self)   // non-array entry: consume to advance
                        continue
                    }
                    guard let xy = try? entry.decode([Double].self), xy.count == 2,
                          let ts = try? entry.decode(Double.self),
                          xy[0].isFinite, xy[1].isFinite else { continue }
                    pts.append(PathPoint(x: xy[0], y: xy[1], ts: ts))
                }
            }
            dataPathData = pts.isEmpty ? nil : pts
        }
        let topPlate = ((try? c.decodeIfPresent(String.self, forKey: .recognizedLicensePlate)) ?? nil)
        let mergedPlate = (topPlate?.isEmpty == false) ? topPlate : dataPlate
        recognizedLicensePlate = (mergedPlate?.isEmpty == false) ? mergedPlate : nil
        recognizedLicensePlateScore =
            ((try? c.decodeIfPresent(Double.self, forKey: .recognizedLicensePlateScore)) ?? nil)
            ?? dataPlateScore
        snapshotFrameTime = ((try? c.decodeIfPresent(Double.self, forKey: .snapshotFrameTime)) ?? nil)
            ?? dataSnapshotFrameTime
        score = ((try? c.decodeIfPresent(Double.self, forKey: .score)) ?? nil) ?? dataScore
        topScore = ((try? c.decodeIfPresent(Double.self, forKey: .topScore)) ?? nil) ?? dataTopScore
        let topDescription = ((try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil)
        let merged = topDescription ?? dataDescription
        description = (merged?.isEmpty == false) ? merged : nil
        pathData = dataPathData
        normBox = dataNormBox
        region = dataRegion
    }
}

struct FrigateReviewItem: Identifiable, Codable, Hashable {
    let id: String
    let camera: String
    let startTime: Double?
    let endTime: Double?
    let severity: String?
    let thumbPath: String?
    let hasBeenReviewed: Bool?
    let data: ReviewData?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case id
        case camera
        case startTime = "start_time"
        case endTime = "end_time"
        case severity
        case thumbPath = "thumb_path"
        case hasBeenReviewed = "has_been_reviewed"
        case data
        case description
    }

    init(id: String, camera: String, startTime: Double?, endTime: Double?, severity: String?,
         thumbPath: String?, hasBeenReviewed: Bool?, data: ReviewData?, description: String?) {
        self.id = id
        self.camera = camera
        self.startTime = startTime
        self.endTime = endTime
        self.severity = severity
        self.thumbPath = thumbPath
        self.hasBeenReviewed = hasBeenReviewed
        self.data = data
        self.description = description
    }

    /// `id` and `camera` are the only fields a review is useless without; everything else
    /// degrades to nil rather than throwing.
    ///
    /// `/api/review` is decoded as one atomic `[FrigateReviewItem]`, so a single review whose
    /// `data` arrives in an unexpected SHAPE (a list, a string, a future object ReviewData's own
    /// lenient decode can't even enter) would rethrow through the synthesized decoder and fail
    /// the ENTIRE array. refresh() swallows that with `try?` and keeps the previous value —
    /// empty on cold start — so the Review tab would show nothing and the badge would read 0
    /// while alerts piled up on the server.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        camera = try c.decode(String.self, forKey: .camera)
        startTime = (try? c.decodeIfPresent(Double.self, forKey: .startTime)) ?? nil
        endTime = (try? c.decodeIfPresent(Double.self, forKey: .endTime)) ?? nil
        severity = (try? c.decodeIfPresent(String.self, forKey: .severity)) ?? nil
        thumbPath = (try? c.decodeIfPresent(String.self, forKey: .thumbPath)) ?? nil
        hasBeenReviewed = (try? c.decodeIfPresent(Bool.self, forKey: .hasBeenReviewed)) ?? nil
        data = (try? c.decodeIfPresent(ReviewData.self, forKey: .data)) ?? nil
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
    }
}

extension FrigateReviewItem {
    /// The AI rating to actually present, or nil when it shouldn't be believed — see
    /// `ThreatLevel.trusted`. Lives here so the row badge, the story card and the live banner all
    /// reach the same verdict from the same inputs; three call sites deciding this independently is
    /// how one of them ends up screaming about a resident with a parcel.
    var trustedThreatLevel: ThreatLevel? {
        ThreatLevel.trusted(raw: data?.metadata?.potentialThreatLevel,
                            confidence: data?.metadata?.confidence,
                            objects: data?.objects ?? [])
    }
}

struct ReviewData: Codable, Hashable {
    let detections: [String]?
    let objects: [String]?
    let subLabels: [String]?
    let zones: [String]?
    let audio: [String]?
    /// Epoch of the frame Frigate chose as this review's canonical thumbnail — the moment the
    /// review is "about". Used to pick which detection's snapshot to show (a review re-links
    /// long-lived parked tracks, so the earliest detection is often the wrong moment).
    let thumbTime: Double?
    /// Which of `objects` Frigate has actually matched to a sub-label (face/plate/name) — a
    /// subset of `objects`, independently deduplicated. `objects` and `subLabels` are NOT
    /// positionally paired (a review with a person + a verified car can have `subLabels: ["My
    /// Truck"]` that belongs to the car, not `objects.first`) — use this to attribute a
    /// sub-label to a specific object instead of guessing `objects.first`.
    let verifiedObjects: [String]?
    /// Frigate 0.18's GenAI **review summary** — a narrative of what happened across the whole
    /// review, with a threat rating. This is a different feature from per-object descriptions
    /// (which answer "who was that"); this one answers "should I care about this one".
    /// Nil until `review.genai` is enabled server-side, and on every review recorded before it was.
    let metadata: ReviewAISummary?

    enum CodingKeys: String, CodingKey {
        case detections
        case objects
        case subLabels = "sub_labels"
        case zones
        case audio
        case thumbTime = "thumb_time"
        case verifiedObjects = "verified_objects"
        case metadata
    }

    init(detections: [String]?, objects: [String]?, subLabels: [String]?, zones: [String]?,
         audio: [String]?, thumbTime: Double?, verifiedObjects: [String]?,
         metadata: ReviewAISummary?) {
        self.detections = detections
        self.objects = objects
        self.subLabels = subLabels
        self.zones = zones
        self.audio = audio
        self.thumbTime = thumbTime
        self.verifiedObjects = verifiedObjects
        self.metadata = metadata
    }

    /// The real fields decode normally; `metadata` is isolated behind `try?`.
    ///
    /// Belt and braces with ReviewAISummary's own lenient decoder: that one survives a bad FIELD,
    /// this one survives `metadata` being an entirely unexpected SHAPE (a string, a number, an
    /// array). The AI summary is a nice-to-have bolted onto a security feed — it must never be
    /// able to cost the user their alerts.
    /// Every field is isolated behind `try?`, not just `metadata`. `/api/review` is decoded as
    /// one atomic `[FrigateReviewItem]`, so a single surprising field — a future Frigate emitting
    /// `sub_labels` as `[["Brandon", 0.98]]` instead of `["Brandon"]`, say — used to throw all the
    /// way out and fail the ENTIRE array; refresh() then kept the previous value, which on cold
    /// start is empty, so the Review tab showed nothing while alerts piled up on the server. This
    /// is the same mechanism as the `other_concerns` regression, which was only fixed for
    /// `metadata`. A field we can't read degrades to nil; the review still lists.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detections = (try? c.decodeIfPresent([String].self, forKey: .detections)) ?? nil
        objects = (try? c.decodeIfPresent([String].self, forKey: .objects)) ?? nil
        subLabels = (try? c.decodeIfPresent([String].self, forKey: .subLabels)) ?? nil
        zones = (try? c.decodeIfPresent([String].self, forKey: .zones)) ?? nil
        audio = (try? c.decodeIfPresent([String].self, forKey: .audio)) ?? nil
        thumbTime = (try? c.decodeIfPresent(Double.self, forKey: .thumbTime)) ?? nil
        verifiedObjects = (try? c.decodeIfPresent([String].self, forKey: .verifiedObjects)) ?? nil
        metadata = (try? c.decodeIfPresent(ReviewAISummary.self, forKey: .metadata)) ?? nil
    }
}

/// Frigate's GenAI narrative for a review item (`review.data.metadata`).
///
/// Every field is optional on purpose: the summary is produced by a language model, older reviews
/// have none at all, and a half-written record must degrade to "show what we have" rather than
/// failing the whole review's decode and blanking the tab.
struct ReviewAISummary: Codable, Hashable {
    /// Headline, e.g. "Daytime Package Delivery at Residence".
    let title: String?
    /// One-sentence version — what the row and the notification want.
    let shortSummary: String?
    /// Full narrative paragraph.
    let scene: String?
    /// Beat-by-beat observations, in order. Reads as a timeline.
    let observations: [String]?
    /// The model's confidence in its own reading, 0…1.
    let confidence: Double?
    /// 0 = routine. Higher means the model thinks it's worth a look. Drives the badge.
    let potentialThreatLevel: Int?
    /// Populated when the activity matched one of the household's `additional_concerns`.
    ///
    /// Frigate sends this as an ARRAY of strings, but `null` when nothing matched — which is all
    /// this field ever was until the feature produced real data, so it was first modelled as a
    /// `String?`. That mismatch threw on decode and took the whole review array with it, blanking
    /// the Review tab. Decoded leniently now: array, bare string, or absent all work.
    let otherConcerns: [String]?
    /// Frigate's own human-readable stamp, e.g. "Monday, 01:28 PM".
    let time: String?

    enum CodingKeys: String, CodingKey {
        case title, scene, observations, confidence, time
        case shortSummary
        case potentialThreatLevel = "potential_threat_level"
        case otherConcerns = "other_concerns"
    }

    init(title: String?, shortSummary: String?, scene: String?, observations: [String]?,
         confidence: Double?, potentialThreatLevel: Int?, otherConcerns: [String]?, time: String?) {
        self.title = title
        self.shortSummary = shortSummary
        self.scene = scene
        self.observations = observations
        self.confidence = confidence
        self.potentialThreatLevel = potentialThreatLevel
        self.otherConcerns = otherConcerns
        self.time = time
    }

    /// Decoded field-by-field with `try?` on purpose.
    ///
    /// This whole struct is filled in by a language model, and Frigate's own shape has already
    /// changed once under us (`other_concerns` went from `null` to an array). A single surprising
    /// type must degrade THAT FIELD to nil — never throw, because a throw here propagates up
    /// through ReviewData and FrigateReviewItem and takes the entire review list with it. That is
    /// exactly how the Review tab went blank, and no future field is allowed to do it again.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        shortSummary = try? c.decodeIfPresent(String.self, forKey: .shortSummary)
        scene = try? c.decodeIfPresent(String.self, forKey: .scene)
        observations = (try? c.decodeIfPresent([String].self, forKey: .observations)) ?? nil
        confidence = try? c.decodeIfPresent(Double.self, forKey: .confidence)
        // An LLM writes this number and Frigate stores it verbatim, so it can arrive as `2.0`.
        // Int-only decoding threw on that, `try?` swallowed it, and a review the model rated
        // "worth acting on" lost its badge and read as routine — the silent-downgrade direction.
        // Int is tried first, so the common case is unchanged and nil still means routine.
        if let exact = try? c.decodeIfPresent(Int.self, forKey: .potentialThreatLevel) {
            potentialThreatLevel = exact
        } else if let approx = try? c.decodeIfPresent(Double.self, forKey: .potentialThreatLevel),
                  approx.isFinite {
            potentialThreatLevel = Int(approx.rounded())
        } else {
            potentialThreatLevel = nil
        }
        time = try? c.decodeIfPresent(String.self, forKey: .time)
        // Array is what Frigate actually sends; a bare string is accepted so a provider that
        // returns one doesn't silently drop the concern.
        if let list = try? c.decodeIfPresent([String].self, forKey: .otherConcerns) {
            otherConcerns = list
        } else if let single = try? c.decodeIfPresent(String.self, forKey: .otherConcerns) {
            otherConcerns = [single]
        } else {
            otherConcerns = nil
        }
    }

    /// True when there's actually something worth rendering.
    var hasContent: Bool {
        !(title ?? "").isEmpty || !(shortSummary ?? "").isEmpty
            || !(scene ?? "").isEmpty || !(observations ?? []).isEmpty
    }

    /// The single best one-liner available. `title` is purpose-written and never clamped, so it
    /// wins; only when it's absent do we fall back — and then to a COMPLETE sentence rather than
    /// the 140-char-clamped `shortSummary`, which would otherwise become a headline ending
    /// mid-word.
    var headline: String? {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return summarySentence
    }

    /// The summary sentence to show under the headline — the best COMPLETE one available.
    ///
    /// Frigate hard-clamps `shortSummary` to 140 characters, slicing mid-word: measured across 61
    /// rated reviews on the live server, **22 (36%) ended mid-sentence** — "…instead moving ",
    /// "…entering through the", "…The person's". Rendering that verbatim is what made the AI card
    /// look broken. In **all 22** cases the `scene` field carried the same narrative, finished:
    /// 184 chars ending "…around the front of the house and along the sidewalk."
    ///
    /// So prefer whichever field is actually a finished sentence, longest first, and only fall back
    /// to a clamped one when nothing complete exists — with the dangling partial word removed and an
    /// ellipsis, so a cut-off summary at least reads as deliberately abbreviated.
    var summarySentence: String? {
        let candidates = [scene, shortSummary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        if let complete = candidates.filter({ Self.readsComplete($0) }).max(by: { $0.count < $1.count }) {
            return complete
        }
        // Nothing ends in punctuation. Only TIDY when the text actually looks clamped — plenty of
        // legitimate short summaries just lack a full stop, and chopping their last word would be
        // vandalism. Frigate's clamp is 140, so anything at that boundary is the machine's cut.
        guard let longest = candidates.max(by: { $0.count < $1.count }) else { return nil }
        return longest.count >= Self.clampLength - 1 ? Self.tidyTruncation(longest) : longest
    }

    /// Frigate's hard clamp on `shortSummary`, measured: the longest observed is exactly 140.
    static let clampLength = 140

    /// A sentence Frigate didn't cut off. Terminal punctuation is the only signal available —
    /// the clamp slices blind, so a clamped string essentially never ends on one.
    static func readsComplete(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?".contains(last)
    }

    /// Drop the half-word the clamp left behind and mark the cut, so it reads as abbreviated rather
    /// than as a sentence that simply stops.
    static func tidyTruncation(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A trailing space means the clamp landed BETWEEN words — nothing to drop, just mark it.
        if !text.hasSuffix(" "), let lastSpace = s.lastIndex(of: " ") {
            s = String(s[s.startIndex..<lastSpace])
        }
        s = s.trimmingCharacters(in: .whitespaces)
        while let last = s.last, ",;:".contains(last) { s.removeLast() }
        return s.isEmpty ? text : s + "…"
    }
}

struct FrigateRecording: Identifiable, Codable, Hashable {
    // Fall back to a stable random id when both timestamps are nil so two timeless rows don't
    // collide on "0.0-0.0" and trip SwiftUI's duplicate-ID warning / row glitches.
    let id: String
    let startTime: Double?
    let endTime: Double?
    let motion: Double?
    let objects: Double?

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case motion
        case objects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Lenient per-field decode (matches FrigateEvent/TimelineBeat): a present-but-wrong-typed
        // field degrades to nil instead of THROWING and failing the whole [FrigateRecording] array —
        // one malformed row must not blank the entire day's recordings.
        startTime = (try? c.decodeIfPresent(Double.self, forKey: .startTime)) ?? nil
        endTime = (try? c.decodeIfPresent(Double.self, forKey: .endTime)) ?? nil
        motion = (try? c.decodeIfPresent(Double.self, forKey: .motion)) ?? nil
        objects = (try? c.decodeIfPresent(Double.self, forKey: .objects)) ?? nil
        if let s = startTime, let e = endTime {
            id = "\(s)-\(e)"
        } else {
            id = UUID().uuidString
        }
    }
}

struct FrigateStats: Codable, Hashable {
    let cameras: [String: CameraStats]?
    let detectors: [String: DetectorStats]?
    let service: ServiceStats?
}

struct CameraStats: Codable, Hashable {
    let cameraFps: Double?
    let detectionFps: Double?
    let processFps: Double?

    enum CodingKeys: String, CodingKey {
        case cameraFps = "camera_fps"
        case detectionFps = "detection_fps"
        case processFps = "process_fps"
    }
}

struct DetectorStats: Codable, Hashable {
    let inferenceSpeed: Double?
    let pid: Int?

    enum CodingKeys: String, CodingKey {
        case inferenceSpeed = "inference_speed"
        case pid
    }
}

struct ServiceStats: Codable, Hashable {
    let uptime: Int?
    let latestVersion: String?
    let storage: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case uptime
        case latestVersion = "latest_version"
        case storage
    }
}

struct CameraCapability: Identifiable, Hashable {
    var id: String { camera }
    let camera: String
    var hasLatestFrame = false
    var hasRecordings = false
    var hasPtz = false
    var hasGo2RtcStream = false
    var zones: [String] = []
    var objects: [String] = []
}

struct FrigateConfig: Codable, Hashable {
    let cameras: [String: CameraConfig]
}

struct CameraConfig: Codable, Hashable {
    let zones: [String: ZoneConfig]?
    let objects: ObjectConfig?
    let detect: DetectConfig?
}

/// Frigate's per-camera detect resolution (`cameras.<name>.detect.{width,height}`).
struct DetectConfig: Codable, Hashable {
    let width: Int?
    let height: Int?
}

struct ZoneConfig: Codable, Hashable {}

struct ObjectConfig: Codable, Hashable {
    let track: [String]?
}

/// Current enabled/disabled state of per-camera Frigate features.
/// Read via `FrigateClient.cameraControlState(camera:)`.
struct CameraControlState: Equatable {
    var detect: Bool = true
    var recordings: Bool = false
    var snapshots: Bool = false
    var audio: Bool = false
    var motion: Bool = true
}

/// Full config used only for reading per-camera feature toggles.
struct FrigateFullConfig: Decodable {
    let cameras: [String: FullCameraConfig]

    struct FullCameraConfig: Decodable {
        let detect: FeatureToggle?
        let record: FeatureToggle?
        let snapshots: FeatureToggle?
        let audio: FeatureToggle?
        let motion: FeatureToggle?
    }

    struct FeatureToggle: Decodable {
        let enabled: Bool?
    }
}

/// A single live detection surfaced from the WebSocket event stream.
struct LiveDetection: Identifiable, Hashable {
    let id: String
    let label: String
    /// Normalized bounding box [x1, y1, x2, y2] in 0-1 fractions of the frame.
    let normBox: CGRect
}

enum FrigateError: LocalizedError {
    case invalidURL
    case loginFailed
    case badResponse(Int)
    /// A human-readable reason surfaced from the server's response body.
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid Frigate server URL."
        case .loginFailed:
            return "Frigate did not return a session token."
        case .badResponse(let statusCode):
            return "Frigate returned status \(statusCode)."
        case .message(let text):
            return text
        }
    }
}

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
