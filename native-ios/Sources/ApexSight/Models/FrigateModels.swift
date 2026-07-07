import Foundation

struct FrigateSession: Codable, Equatable {
    let baseURL: URL
    let username: String
    let token: String
    /// Retained in the device-only Keychain so the app can silently refresh the
    /// `frigate_token` JWT on a 401 (e.g. mid-stream token expiry) by re-running the
    /// existing login. Optional so previously-stored sessions still decode.
    let password: String?

    init(baseURL: URL, username: String, token: String, password: String? = nil) {
        self.baseURL = baseURL
        self.username = username
        self.token = token
        self.password = password
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
    /// Bounding box in pixels [x1, y1, x2, y2] from the WebSocket event stream.
    /// Pair with `frameWidth`/`frameHeight` to get 0-1 normalized overlay coords.
    let box: [Double]?
    let frameWidth: Double?
    let frameHeight: Double?

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
        recognizedLicensePlate = try? c.decodeIfPresent(String.self, forKey: .recognizedLicensePlate)
        recognizedLicensePlateScore = try? c.decodeIfPresent(Double.self, forKey: .recognizedLicensePlateScore)
        searchDistance = try? c.decodeIfPresent(Double.self, forKey: .searchDistance)
        searchSource = try? c.decodeIfPresent(String.self, forKey: .searchSource)
        box = try? c.decodeIfPresent([Double].self, forKey: .box)
        frameWidth = try? c.decodeIfPresent(Double.self, forKey: .frameWidth)
        frameHeight = try? c.decodeIfPresent(Double.self, forKey: .frameHeight)

        // score / top_score / description can be top-level OR nested under `data`
        // (the /events/search response nests them) — read both, preferring top-level.
        var dataScore: Double?, dataTopScore: Double?, dataDescription: String?
        if let dataOuter = try? decoder.container(keyedBy: DataOuterKeys.self),
           let dataC = try? dataOuter.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
            dataScore = try? dataC.decodeIfPresent(Double.self, forKey: .score)
            dataTopScore = try? dataC.decodeIfPresent(Double.self, forKey: .topScore)
            dataDescription = try? dataC.decodeIfPresent(String.self, forKey: .description)
        }
        score = ((try? c.decodeIfPresent(Double.self, forKey: .score)) ?? nil) ?? dataScore
        topScore = ((try? c.decodeIfPresent(Double.self, forKey: .topScore)) ?? nil) ?? dataTopScore
        let topDescription = ((try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil)
        let merged = topDescription ?? dataDescription
        description = (merged?.isEmpty == false) ? merged : nil
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
}

struct ReviewData: Codable, Hashable {
    let detections: [String]?
    let objects: [String]?
    let subLabels: [String]?
    let zones: [String]?
    let audio: [String]?

    enum CodingKeys: String, CodingKey {
        case detections
        case objects
        case subLabels = "sub_labels"
        case zones
        case audio
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
        startTime = try c.decodeIfPresent(Double.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(Double.self, forKey: .endTime)
        motion = try c.decodeIfPresent(Double.self, forKey: .motion)
        objects = try c.decodeIfPresent(Double.self, forKey: .objects)
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
