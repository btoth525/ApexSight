import Foundation
import UIKit

// MARK: - Display message model

struct AIMessage: Identifiable {
    let id: UUID
    enum Role { case user, assistant, tool, error }
    enum ToolStatus { case running, done, failed }

    let role: Role
    var text: String
    var toolStatus: ToolStatus?
    var thumbnail: UIImage?

    init(id: UUID = UUID(), role: Role, text: String,
         toolStatus: ToolStatus? = nil, thumbnail: UIImage? = nil) {
        self.id = id; self.role = role; self.text = text
        self.toolStatus = toolStatus; self.thumbnail = thumbnail
    }

    static func user(_ t: String) -> AIMessage { .init(role: .user, text: t) }
    static func assistant(_ t: String) -> AIMessage { .init(role: .assistant, text: t) }
    static func error(_ t: String) -> AIMessage { .init(role: .error, text: t) }
}

// MARK: - Claude API client

final class ClaudeAPIClient {
    static let shared = ClaudeAPIClient()
    private init() {}

    static let apiKeyDefaultsKey = "claude_api_key"
    var apiKey: String { UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey) ?? "" }

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    // Fast, inexpensive model — perfect for security Q&A and tool use.
    private let model = "claude-haiku-4-5-20251001"

    // MARK: - Response types

    struct Response: Decodable {
        let content: [Block]
        let stopReason: String?
        enum CodingKeys: String, CodingKey {
            case content; case stopReason = "stop_reason"
        }
    }

    struct Block: Decodable {
        let type: String
        let text: String?     // type == "text"
        let id: String?       // type == "tool_use"
        let name: String?     // type == "tool_use"
        let input: JSONValue? // type == "tool_use" — arbitrary JSON object
    }

    enum APIError: LocalizedError {
        case noAPIKey, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No Claude API key. Add one in Settings → AI Assistant."
            case .http(401, _):
                return "Invalid Claude API key. Double-check it in Settings → AI Assistant."
            case .http(let code, let body):
                // Extract the human-readable message from the error JSON if possible.
                if let data = body.data(using: .utf8),
                   let json = try? JSONDecoder().decode([String: JSONValue].self, from: data),
                   case .string(let msg) = json["error"]?.objectValue?["message"] {
                    return "Claude: \(msg)"
                }
                return "Claude API error \(code)"
            }
        }
    }

    // MARK: - API call

    func complete(messages: [[String: Any]], system: String) async throws -> Response {
        guard !apiKey.isEmpty else { throw APIError.noAPIKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "tools": Self.frigateTools,
            "messages": messages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    // MARK: - Frigate tool definitions (mirrors mcp-frigate's 7 tools + semantic search)

    static let frigateTools: [[String: Any]] = [
        tool("get_cameras",
             desc: "List all configured cameras with names and settings."),
        tool("get_events",
             desc: "Get detection events. Use for questions about what was detected, who visited, what happened. Returns camera, label (person/car/dog/etc), confidence %, time, and zones.",
             props: [
                "camera": p("string", "Camera name to filter by (optional)"),
                "label":  p("string", "Object type: person, car, dog, cat, bird, etc. (optional)"),
                "limit":  p("integer", "Max events 1-100, default 20"),
                "after":  p("number", "Unix timestamp — only events after this time (optional)"),
                "before": p("number", "Unix timestamp — only events before this time (optional)")
             ]),
        tool("get_event_details",
             desc: "Get full details + thumbnail image for a specific event. Use event IDs from get_events.",
             props: ["event_id": p("string", "The event ID")],
             required: ["event_id"]),
        tool("get_snapshot",
             desc: "Fetch the live camera snapshot. You will receive the actual image and can describe what you see.",
             props: ["camera": p("string", "Camera name")],
             required: ["camera"]),
        tool("get_stats",
             desc: "System performance: camera FPS, AI detector inference speed, storage, uptime."),
        tool("get_recordings",
             desc: "Recording summary for a camera on a specific date.",
             props: [
                "camera": p("string", "Camera name"),
                "date":   p("string", "Date as YYYY-MM-DD, defaults to today")
             ],
             required: ["camera"]),
        tool("search_events",
             desc: "Semantic / natural-language search across events. Great for queries like 'person with backpack', 'yellow car', 'delivery person'. More powerful than get_events for descriptive questions.",
             props: [
                "query":  p("string", "Natural language description to search for"),
                "camera": p("string", "Limit to this camera (optional)"),
                "limit":  p("integer", "Max results, default 10")
             ],
             required: ["query"])
    ]

    private static func tool(_ name: String, desc: String,
                              props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": desc, "input_schema": schema]
    }

    private static func p(_ type: String, _ desc: String) -> [String: Any] {
        ["type": type, "description": desc]
    }
}

// MARK: - JSONValue convenience for tool input parsing

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let d) = self { return d }; return nil
    }
    subscript(key: String) -> JSONValue? { objectValue?[key] }
    var stringValue: String? {
        if case .string(let s) = self { return s }; return nil
    }
    var doubleValue: Double? {
        if case .number(let n) = self { return n }; return nil
    }
    var intValue: Int? { doubleValue.map { Int($0) } }
}
