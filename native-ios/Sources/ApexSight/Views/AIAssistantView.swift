import SwiftUI
import UIKit

// MARK: - Conversation manager

@MainActor
final class AIConversation: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var isThinking = false

    private var apiMessages: [[String: Any]] = []

    private let systemPrompt = """
    You are an AI security assistant built into ApexSight, a Frigate NVR home security app. \
    Help the user understand what's happening on their cameras, review events, check system \
    health, and answer questions about their home security.

    Use the tools to fetch real data — never make things up. When you get a snapshot, \
    describe what you actually see in the image. Be concise: 1-3 sentences for simple \
    questions, short lists for multiple events. Format times as "Today at 2:30 PM" or \
    "Yesterday at 11:45 PM". When listing events, lead with the most important or recent.
    """

    // MARK: - Public

    func send(_ text: String, appState: AppState) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client = appState.client else {
            messages.append(.error("Not connected to Frigate. Check Settings."))
            return
        }

        messages.append(.user(trimmed))
        apiMessages.append(["role": "user", "content": [["type": "text", "text": trimmed]]])
        isThinking = true

        do {
            try await runLoop(client: client)
        } catch {
            messages.append(.error(error.localizedDescription))
        }

        isThinking = false
    }

    func clear() {
        messages.removeAll()
        apiMessages.removeAll()
    }

    // MARK: - Tool-use loop

    private func runLoop(client: FrigateClient) async throws {
        for _ in 0..<10 {
            let response = try await ClaudeAPIClient.shared.complete(
                messages: apiMessages, system: systemPrompt
            )

            let toolCalls = response.content.filter { $0.type == "tool_use" }
            let textParts  = response.content.filter { $0.type == "text"     }

            // Encode the assistant turn into history before executing tools.
            apiMessages.append(["role": "assistant",
                                 "content": response.content.map { encodeBlock($0) }])

            // Any text that precedes tool calls — show it.
            let preText = textParts.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !preText.isEmpty && !toolCalls.isEmpty { messages.append(.assistant(preText)) }

            if toolCalls.isEmpty {
                // Final turn — show the answer.
                let answer = textParts.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty { messages.append(.assistant(answer)) }
                return
            }

            // Execute each tool and collect results.
            var toolResults: [[String: Any]] = []
            for call in toolCalls {
                guard let callId = call.id, let callName = call.name else { continue }

                let rowId = UUID()
                messages.append(AIMessage(id: rowId, role: .tool,
                                          text: label(for: callName), toolStatus: .running))

                let result = await executeTool(name: callName, input: call.input, client: client)
                updateRow(id: rowId, status: result.isError ? .failed : .done, thumb: result.thumbnail)
                toolResults.append(result.apiDict(toolUseId: callId))
            }

            apiMessages.append(["role": "user", "content": toolResults])
        }
    }

    private func updateRow(id: UUID, status: AIMessage.ToolStatus, thumb: UIImage?) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].toolStatus = status
        if let t = thumb { messages[idx].thumbnail = t }
    }

    // Encode a response block back into the dict format the API expects in history.
    private func encodeBlock(_ block: ClaudeAPIClient.Block) -> [String: Any] {
        switch block.type {
        case "text":
            return ["type": "text", "text": block.text ?? ""]
        case "tool_use":
            var d: [String: Any] = [
                "type": "tool_use",
                "id":   block.id   ?? "",
                "name": block.name ?? ""
            ]
            d["input"] = block.input.map { anyValue($0) } ?? ([:] as [String: Any])
            return d
        default:
            return ["type": block.type]
        }
    }

    // MARK: - Tool executor

    struct ToolResult {
        let isError: Bool
        let textContent: String
        let imageData: Data?
        let thumbnail: UIImage?

        func apiDict(toolUseId: String) -> [String: Any] {
            if let img = imageData {
                return [
                    "type": "tool_result",
                    "tool_use_id": toolUseId,
                    "content": [
                        ["type": "image",
                         "source": ["type": "base64",
                                    "media_type": "image/jpeg",
                                    "data": img.base64EncodedString()]],
                        ["type": "text", "text": textContent]
                    ]
                ]
            }
            var d: [String: Any] = ["type": "tool_result",
                                    "tool_use_id": toolUseId,
                                    "content": textContent]
            if isError { d["is_error"] = true }
            return d
        }

        static func text(_ s: String) -> ToolResult {
            .init(isError: false, textContent: s, imageData: nil, thumbnail: nil)
        }
        static func fail(_ s: String) -> ToolResult {
            .init(isError: true, textContent: s, imageData: nil, thumbnail: nil)
        }
        static func image(raw: Data, caption: String) -> ToolResult {
            let thumb = UIImage(data: raw).flatMap { resized($0, maxWidth: 80) }
            let api   = shrink(raw, maxWidth: 640)
            return .init(isError: false, textContent: caption, imageData: api, thumbnail: thumb)
        }

        private static func shrink(_ data: Data, maxWidth: CGFloat) -> Data {
            guard let img = UIImage(data: data), img.size.width > maxWidth else { return data }
            let scale = maxWidth / img.size.width
            let size  = CGSize(width: maxWidth, height: img.size.height * scale)
            return UIGraphicsImageRenderer(size: size).image { _ in
                img.draw(in: CGRect(origin: .zero, size: size))
            }.jpegData(compressionQuality: 0.65) ?? data
        }

        private static func resized(_ img: UIImage, maxWidth: CGFloat) -> UIImage? {
            guard img.size.width > 0 else { return nil }
            let scale = min(maxWidth / img.size.width, 1)
            let size  = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            return UIGraphicsImageRenderer(size: size).image { _ in
                img.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }

    private func executeTool(name: String, input: JSONValue?,
                             client: FrigateClient) async -> ToolResult {
        let inp = input?.objectValue ?? [:]
        do {
            switch name {

            // ── Cameras ───────────────────────────────────────────────────────
            case "get_cameras":
                let cams = try await client.cameras()
                let list = cams.map { c -> [String: Any] in
                    ["name": c.name, "zones": c.zones, "objects": c.objects]
                }
                return .text(json(["cameras": list, "count": list.count]) ?? "[]")

            // ── Events ────────────────────────────────────────────────────────
            case "get_events":
                let camera = inp["camera"]?.stringValue
                let label  = inp["label"]?.stringValue
                let limit  = inp["limit"]?.intValue ?? 20
                let after  = inp["after"]?.doubleValue.map  { Date(timeIntervalSince1970: $0) }
                let before = inp["before"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
                let evts = try await client.events(
                    camera: camera, label: label, subLabel: nil, zone: nil,
                    after: after, before: before,
                    limit: min(limit, 50), hasClip: nil, hasSnapshot: nil
                )
                return .text(encodeEvents(evts, client: client))

            // ── Event details + thumbnail ─────────────────────────────────────
            case "get_event_details":
                guard let eid = inp["event_id"]?.stringValue else {
                    return .fail("event_id is required")
                }
                let evt = try await client.event(id: eid)
                let thumbURL = client.eventThumbnailURL(id: eid)
                if let imgData = try? await client.imageData(from: thumbURL) {
                    let caption = "Event on \(evt.camera): \(evt.label)" +
                        (evt.startTime.map { " at \(fmtTime(Date(timeIntervalSince1970: $0)))" } ?? "") +
                        (evt.topScore.map { ", \(Int($0 * 100))% confidence" } ?? "") +
                        (evt.zones.map { !$0.isEmpty ? ", zones: \($0.joined(separator: ","))" : "" } ?? "")
                    return .image(raw: imgData, caption: caption)
                }
                return .text(encodeEvent(evt, client: client))

            // ── Snapshot (Claude actually sees the image) ─────────────────────
            case "get_snapshot":
                guard let camera = inp["camera"]?.stringValue else {
                    return .fail("camera is required")
                }
                var components = URLComponents(
                    url: client.latestFrameURL(camera: camera),
                    resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "height", value: "480")]
                let snapURL = components?.url ?? client.latestFrameURL(camera: camera)
                let imgData = try await client.imageData(from: snapURL)
                return .image(raw: imgData, caption: "Live snapshot from camera '\(camera)'")

            // ── System stats ──────────────────────────────────────────────────
            case "get_stats":
                let stats = try await client.stats()
                var d: [String: Any] = [:]
                if let svc = stats.service {
                    d["uptime_hours"] = (svc.uptime ?? 0) / 3600
                }
                if let cams = stats.cameras {
                    d["camera_fps"] = Dictionary(uniqueKeysWithValues: cams.map {
                        ($0.key, ["fps": $0.value.cameraFps ?? 0,
                                  "detection_fps": $0.value.detectionFps ?? 0])
                    })
                }
                if let det = stats.detectors {
                    d["detectors"] = Dictionary(uniqueKeysWithValues: det.map {
                        ($0.key, ["inference_ms": $0.value.inferenceSpeed ?? 0])
                    })
                }
                return .text(json(d) ?? "Stats unavailable")

            // ── Recordings ────────────────────────────────────────────────────
            case "get_recordings":
                guard let camera = inp["camera"]?.stringValue else {
                    return .fail("camera is required")
                }
                let cal    = Calendar.current
                let date   = inp["date"]?.stringValue.flatMap { parseDate($0) } ?? Date()
                let start  = cal.startOfDay(for: date)
                let end    = cal.date(byAdding: .day, value: 1, to: start) ?? start
                let recs   = try await client.recordings(camera: camera, after: start, end: end)
                // JSONEncoder the raw Codable model so we don't need to know its fields.
                if let data = try? JSONEncoder().encode(recs),
                   let str = String(data: data, encoding: .utf8) {
                    return .text("{\"camera\":\"\(camera)\",\"date\":\"\(inp["date"]?.stringValue ?? "today")\",\"count\":\(recs.count),\"segments\":\(str)}")
                }
                return .text("Camera: \(camera), Recordings: \(recs.count) segments")

            // ── Semantic search ───────────────────────────────────────────────
            case "search_events":
                guard let query = inp["query"]?.stringValue else {
                    return .fail("query is required")
                }
                let camera = inp["camera"]?.stringValue
                let limit  = inp["limit"]?.intValue ?? 10
                let evts: [FrigateEvent]
                do {
                    evts = try await client.semanticSearch(
                        query: query, camera: camera, label: nil,
                        subLabel: nil, zone: nil, after: nil, before: nil,
                        limit: min(limit, 20)
                    )
                } catch {
                    // Semantic search needs Frigate's embeddings feature. Fall back gracefully.
                    evts = (try? await client.events(
                        camera: camera, label: nil, subLabel: nil, zone: nil,
                        after: nil, before: nil, limit: min(limit, 20),
                        hasClip: nil, hasSnapshot: nil
                    )) ?? []
                }
                if evts.isEmpty { return .text("No events found matching '\(query)'") }
                return .text(encodeEvents(evts, client: client))

            default:
                return .fail("Unknown tool: \(name)")
            }
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    // MARK: - Encoding helpers

    private func encodeEvents(_ events: [FrigateEvent], client: FrigateClient) -> String {
        let list = events.map { e -> [String: Any] in
            var d: [String: Any] = [
                "id":           e.id,
                "camera":       e.camera,
                "label":        e.label,
                "confidence":   e.topScore.map { Int($0 * 100) } ?? 0,
                "thumbnail_url": client.eventThumbnailURL(id: e.id).absoluteString
            ]
            if let st = e.startTime { d["time"] = fmtTime(Date(timeIntervalSince1970: st)) }
            if let et = e.endTime, let st = e.startTime { d["duration_s"] = Int(et - st) }
            if let s = e.subLabel  { d["sub_label"] = s }
            if let z = e.zones, !z.isEmpty { d["zones"] = z }
            if let desc = e.description { d["description"] = desc }
            return d
        }
        return json(["events": list, "count": list.count]) ?? "[]"
    }

    private func encodeEvent(_ e: FrigateEvent, client: FrigateClient) -> String {
        var d: [String: Any] = [
            "id": e.id, "camera": e.camera, "label": e.label,
            "confidence":   e.topScore.map { Int($0 * 100) } ?? 0,
            "has_clip":     e.hasClip ?? false,
            "has_snapshot": e.hasSnapshot ?? false,
            "thumbnail_url": client.eventThumbnailURL(id: e.id).absoluteString
        ]
        if let st = e.startTime { d["time"] = fmtTime(Date(timeIntervalSince1970: st)) }
        if let z = e.zones      { d["zones"] = z }
        if let s = e.subLabel   { d["sub_label"] = s }
        if let desc = e.description { d["description"] = desc }
        return json(d) ?? "{}"
    }

    private func json(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func anyValue(_ v: JSONValue) -> Any {
        switch v {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b):   return b
        case .object(let d): return d.mapValues { anyValue($0) }
        case .array(let a):  return a.map { anyValue($0) }
        case .null:          return NSNull()
        }
    }

    private func fmtTime(_ date: Date) -> String {
        let cal = Calendar.current
        let tf  = DateFormatter()
        tf.timeStyle = .short; tf.dateStyle = .none
        if cal.isDateInToday(date)     { return "Today at \(tf.string(from: date))" }
        if cal.isDateInYesterday(date) { return "Yesterday at \(tf.string(from: date))" }
        tf.dateStyle = .medium
        return tf.string(from: date)
    }

    private func parseDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s)
    }

    private func label(for tool: String) -> String {
        switch tool {
        case "get_cameras":       return "Listing cameras"
        case "get_events":        return "Loading events"
        case "get_event_details": return "Getting event details"
        case "get_snapshot":      return "Taking snapshot"
        case "get_stats":         return "Checking system stats"
        case "get_recordings":    return "Loading recordings"
        case "search_events":     return "Searching events"
        default:                  return "Running \(tool)"
        }
    }
}

// MARK: - Chat UI

struct AIAssistantView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var convo = AIConversation()
    @State private var inputText = ""
    @FocusState private var focused: Bool
    @AppStorage(ClaudeAPIClient.apiKeyDefaultsKey) private var apiKey = ""

    private let suggestions = [
        "What happened today?",
        "Any person detections in the last hour?",
        "Show me a snapshot of my cameras",
        "Check my camera status",
        "Search for package deliveries"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                VStack(spacing: 0) {
                    messagesArea
                    inputBar
                }
            }
            .navigationTitle("AI Assistant")
            .navigationBarTitleDisplayMode(.large)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !convo.messages.isEmpty {
                        Button {
                            Haptics.select()
                            withAnimation { convo.clear() }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(GlassTheme.accent)
                        }
                        .accessibilityLabel("New conversation")
                    }
                }
            }
        }
    }

    // MARK: - Messages

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                    if convo.messages.isEmpty {
                        emptyState
                            .padding(.top, GlassTheme.Space.xl)
                    } else {
                        ForEach(convo.messages) { msg in
                            msgRow(msg).id(msg.id)
                        }
                        if convo.isThinking {
                            thinkingDot.id("thinking")
                        }
                    }
                }
                .padding(.horizontal, GlassTheme.Space.l)
                .padding(.vertical, GlassTheme.Space.m)
                .padding(.bottom, GlassTheme.Space.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: convo.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    if let last = convo.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: convo.isThinking) { _, on in
                if on { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func msgRow(_ msg: AIMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(msg.text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, GlassTheme.Space.m)
                    .padding(.vertical, GlassTheme.Space.s)
                    .background(GlassTheme.accent,
                                in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip,
                                                     style: .continuous))
                    .textSelection(.enabled)
            }

        case .assistant:
            HStack(alignment: .top, spacing: GlassTheme.Space.s) {
                sparkleIcon
                Text(msg.text)
                    .font(.subheadline)
                    .foregroundStyle(GlassTheme.primary)
                    .textSelection(.enabled)
                Spacer(minLength: 16)
            }

        case .tool:
            HStack(spacing: GlassTheme.Space.s) {
                toolIcon(msg.toolStatus ?? .running)
                if let thumb = msg.thumbnail {
                    Image(uiImage: thumb)
                        .resizable().scaledToFill()
                        .frame(width: 40, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Text(msg.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GlassTheme.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, GlassTheme.Space.m)
            .padding(.vertical, GlassTheme.Space.s)
            .background(GlassTheme.surface,
                        in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip,
                                             style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                    .strokeBorder(GlassTheme.separator, lineWidth: 1)
            }

        case .error:
            HStack(spacing: GlassTheme.Space.s) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(GlassTheme.red)
                Text(msg.text)
                    .font(.caption)
                    .foregroundStyle(GlassTheme.red)
            }
        }
    }

    @ViewBuilder
    private func toolIcon(_ status: AIMessage.ToolStatus) -> some View {
        switch status {
        case .running:
            ProgressView().scaleEffect(0.65).tint(GlassTheme.accent).frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.bold)).foregroundStyle(GlassTheme.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption.weight(.bold)).foregroundStyle(GlassTheme.red)
        }
    }

    private var sparkleIcon: some View {
        Image(systemName: "sparkles")
            .font(.caption.weight(.bold))
            .foregroundStyle(GlassTheme.accent)
            .frame(width: 22, height: 22)
            .background(GlassTheme.accent.opacity(0.12), in: Circle())
            .padding(.top, 2)
    }

    private var thinkingDot: some View {
        HStack(spacing: GlassTheme.Space.s) {
            sparkleIcon
            ProgressView().tint(GlassTheme.accent).scaleEffect(0.7)
        }
    }

    // MARK: - Empty / no-key state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
            if apiKey.isEmpty {
                HStack(spacing: GlassTheme.Space.s) {
                    Image(systemName: "key.fill").foregroundStyle(GlassTheme.orange)
                    Text("Add your Claude API key in Settings → AI Assistant to get started.")
                        .font(.subheadline).foregroundStyle(GlassTheme.secondary)
                }
                .padding(GlassTheme.Space.m)
                .background(GlassTheme.orange.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip))
            } else {
                VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(GlassTheme.accent)
                    Text("AI Assistant")
                        .font(.title2.weight(.bold)).foregroundStyle(GlassTheme.primary)
                    Text("Ask anything about your cameras, events, and security system.")
                        .font(.subheadline).foregroundStyle(GlassTheme.secondary)
                }
                VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                    Text("Try asking…")
                        .font(.caption.weight(.semibold)).foregroundStyle(GlassTheme.secondary)
                    // Simple horizontal scroll of suggestion chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: GlassTheme.Space.s) {
                            ForEach(suggestions, id: \.self) { s in
                                suggestionChip(s)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    // Second row
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: GlassTheme.Space.s) {
                            ForEach(suggestions.dropFirst(2), id: \.self) { s in
                                suggestionChip(s)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            Haptics.select()
            inputText = text
            submitMessage()
        } label: {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(GlassTheme.accent)
                .padding(.horizontal, GlassTheme.Space.m)
                .padding(.vertical, GlassTheme.Space.s)
                .background(GlassTheme.accent.opacity(0.10), in: Capsule())
                .overlay { Capsule().strokeBorder(GlassTheme.accent.opacity(0.3), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: GlassTheme.Space.m) {
                TextField("Ask about your cameras…", text: $inputText, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { submitMessage() }
                    .disabled(convo.isThinking || apiKey.isEmpty)

                Button { submitMessage() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? GlassTheme.accent : GlassTheme.tertiary)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.vertical, GlassTheme.Space.m)
        }
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !convo.isThinking
        && !apiKey.isEmpty
    }

    private func submitMessage() {
        guard canSend else { return }
        let text = inputText; inputText = ""
        Haptics.tap()
        Task { await convo.send(text, appState: appState) }
    }
}
