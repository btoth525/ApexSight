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

        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else if trimmed.hasPrefix("192.168.") || trimmed.hasPrefix("10.") || trimmed.hasPrefix("127.") || trimmed == "localhost" || isLAN172(host: trimmed) {
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

struct FrigateCamera: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let zones: [String]
    let objects: [String]
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
    var id: String { "\(startTime ?? 0)-\(endTime ?? 0)" }
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
}

struct ZoneConfig: Codable, Hashable {}

struct ObjectConfig: Codable, Hashable {
    let track: [String]?
}

enum FrigateError: LocalizedError {
    case invalidURL
    case loginFailed
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid Frigate server URL."
        case .loginFailed:
            return "Frigate did not return a session token."
        case .badResponse(let statusCode):
            return "Frigate returned status \(statusCode)."
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
