import SwiftUI

/// "Ask Your Cameras" — a natural-language Q&A that runs entirely on-device:
/// it parses your question into Frigate event filters (object, camera, time,
/// known/unknown faces & plates), queries your Frigate, and answers with a
/// plain-language summary plus the matching clips. No cloud, no LLM.
struct AskView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var styleStore = NotificationStyleStore()

    @State private var question = ""
    @State private var answer: String?
    @State private var results: [FrigateEvent] = []
    @State private var loading = false
    @State private var path = NavigationPath()
    @State private var faceNames: [String] = []
    @Environment(\.dismiss) private var dismiss

    private let suggestions = [
        "Any packages today?",
        "Unknown people this week",
        "When was the dog out last?",
        "Cars in the driveway today",
        "Anyone at the front door today?"
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(spacing: GlassTheme.Space.l) {
                        askBar
                        if loading {
                            HStack { Spacer(); ProgressView().tint(GlassTheme.accent); Spacer() }
                                .padding(.top, 40)
                        } else if let answer {
                            answerCard(answer)
                            if results.isEmpty {
                                EmptyStateView(
                                    icon: "magnifyingglass",
                                    title: "No matches",
                                    message: "No clips matched your question."
                                )
                            } else {
                                resultsGrid
                            }
                        } else {
                            suggestionsCard
                        }
                    }
                    .padding(GlassTheme.Space.l)
                }
            }
            .navigationTitle("Ask Your Cameras")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .navigationDestination(for: FrigateEvent.self) { EventDetailView(event: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // Load known people so questions like "when was Alex seen" resolve.
                if faceNames.isEmpty, let client = appState.client, let faces = try? await client.faces() {
                    faceNames = Array(faces.keys)
                }
            }
        }
    }

    // MARK: - UI

    private var askBar: some View {
        HStack(spacing: GlassTheme.Space.s) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(GlassTheme.secondary)
            TextField("Ask about your cameras…", text: $question)
                .font(.body)
                .foregroundStyle(GlassTheme.primary)
                .submitLabel(.search)
                .onSubmit { Task { await ask() } }
            if !question.isEmpty {
                Button {
                    question = ""; answer = nil; results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(GlassTheme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, GlassTheme.Space.m)
        .padding(.vertical, 10)
        .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
        .cardStroke(GlassTheme.Radius.chip)
    }

    private var suggestionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Try asking")
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        question = s
                        Task { await ask() }
                    } label: {
                        HStack(spacing: GlassTheme.Space.s) {
                            Image(systemName: "sparkle")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(GlassTheme.accent)
                            Text(s)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(GlassTheme.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(GlassTheme.tertiary)
                        }
                        .padding(GlassTheme.Space.m)
                        .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
                        .cardStroke(GlassTheme.Radius.chip)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func answerCard(_ text: String) -> some View {
        GlassCard {
            HStack(alignment: .top, spacing: GlassTheme.Space.m) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GlassTheme.accent)
                Text(text)
                    .font(.body)
                    .foregroundStyle(GlassTheme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: GlassTheme.Space.s)], spacing: GlassTheme.Space.s) {
            ForEach(results.prefix(30)) { event in
                Button { path.append(event) } label: {
                    // Adaptive ~104pt tile — downsample instead of decoding the full frame.
                    RemoteImage(url: appState.client?.eventThumbnailURL(id: event.id), maxPixelSize: 360)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous)
                                .strokeBorder(GlassTheme.separator, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Logic

    private func ask() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let client = appState.client else { return }
        // Re-entrancy guard: tapping a suggestion (or Return) while a question is in
        // flight would race two requests on the shared answer/results state.
        guard !loading else { return }
        loading = true
        defer { loading = false }

        let plan = AskParser.interpret(
            q,
            cameras: appState.cameras.map(\.name),
            faceNames: faceNames,
            style: styleStore.style
        )

        // Pull a generous window, then refine on-device.
        let raw = (try? await client.events(
            camera: plan.camera,
            label: plan.label,
            after: plan.after,
            before: plan.before,
            limit: 200
        )) ?? []

        let filtered = raw.filter { plan.matches($0, style: styleStore.style) }
            .sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }

        results = filtered
        answer = AskParser.answer(for: plan, results: filtered)
    }
}

// MARK: - On-device question parser

struct AskPlan {
    var label: String?
    var camera: String?
    var after: Date?
    var before: Date?
    var unknownOnly = false
    var personName: String?
    var wantsLatest = false
    var subjectSingular = "event"
    var subjectPlural = "events"
    var rangeLabel = "today"

    func matches(_ e: FrigateEvent, style: NotificationStyle) -> Bool {
        if unknownOnly, !(e.subLabel?.isEmpty ?? true) { return false }
        if let name = personName {
            guard let face = e.recognizedFace, face.caseInsensitiveCompare(name) == .orderedSame else { return false }
        }
        return true
    }
}

enum AskParser {
    private static let labelMap: [(keys: [String], label: String, singular: String, plural: String)] = [
        (["package", "delivery", "deliveries", "amazon", "ups", "fedex", "usps", "mail"], "package", "package", "packages"),
        (["person", "people", "someone", "somebody", "anyone", "intruder", "stranger",
          "kid", "kids", "child", "children", "toddler", "baby", "boy", "girl",
          "man", "woman", "guy", "lady"], "person", "person", "people"),
        (["car", "vehicle", "vehicles", "automobile", "sedan", "suv"], "car", "car", "cars"),
        (["truck", "van", "pickup"], "truck", "truck", "trucks"),
        (["dog", "pet", "puppy"], "dog", "dog", "dogs"),
        (["cat", "kitten"], "cat", "cat", "cats"),
        (["bike", "bicycle", "cyclist"], "bicycle", "bike", "bikes"),
        (["bird"], "bird", "bird", "birds"),
        (["motorcycle", "motorbike", "scooter"], "motorcycle", "motorcycle", "motorcycles"),
    ]

    /// Every Frigate object label implied by a free-text query — e.g. "kid on a bike"
    /// → ["person", "bicycle"]. Unlike `interpret`, this does NOT stop at the first
    /// match, so multi-object descriptions surface all relevant detections.
    static func impliedLabels(in q: String) -> [String] {
        let text = q.lowercased()
        var labels: [String] = []
        for entry in labelMap where entry.keys.contains(where: { text.contains($0) }) {
            if !labels.contains(entry.label) { labels.append(entry.label) }
        }
        return labels
    }

    static func interpret(_ q: String, cameras: [String], faceNames: [String], style: NotificationStyle) -> AskPlan {
        let text = q.lowercased()
        var plan = AskPlan()

        // Object
        for entry in labelMap where entry.keys.contains(where: { text.contains($0) }) {
            plan.label = entry.label
            plan.subjectSingular = entry.singular
            plan.subjectPlural = entry.plural
            break
        }

        // Camera (match the camera's words against the question)
        for camera in cameras {
            let words = camera.replacingOccurrences(of: "_", with: " ").lowercased()
            if text.contains(words) || words.split(separator: " ").allSatisfy({ text.contains($0) && $0.count > 2 }) {
                plan.camera = camera
                break
            }
        }

        // Unknown people
        if (text.contains("unknown") || text.contains("stranger") || text.contains("unrecognized")) {
            plan.unknownOnly = true
            if plan.label == nil { plan.label = "person"; plan.subjectSingular = "unknown person"; plan.subjectPlural = "unknown people" }
        }

        // Known face by name
        for name in faceNames where text.contains(name.lowercased()) {
            plan.personName = name
        }

        // "last / when did ... last"
        if text.contains("last") || text.contains("when ") || text.hasPrefix("when") {
            plan.wantsLatest = true
        }

        // Time range
        let cal = Calendar.current
        let now = Date()
        if text.contains("yesterday") {
            let startToday = cal.startOfDay(for: now)
            plan.after = cal.date(byAdding: .day, value: -1, to: startToday)
            plan.before = startToday
            plan.rangeLabel = "yesterday"
        } else if text.contains("this week") || text.contains("past week") || text.contains(" week") {
            plan.after = cal.date(byAdding: .day, value: -7, to: now)
            plan.rangeLabel = "this week"
        } else if text.contains("this month") || text.contains("past month") || text.contains(" month") {
            plan.after = cal.date(byAdding: .day, value: -30, to: now)
            plan.rangeLabel = "this month"
        } else if text.contains("hour") {
            plan.after = cal.date(byAdding: .hour, value: -1, to: now)
            plan.rangeLabel = "in the last hour"
        } else if text.contains("tonight") || text.contains("last night") {
            plan.after = cal.date(byAdding: .hour, value: -12, to: now)
            plan.rangeLabel = "tonight"
        } else {
            // Default: today
            plan.after = cal.startOfDay(for: now)
            plan.rangeLabel = "today"
        }
        return plan
    }

    static func answer(for plan: AskPlan, results: [FrigateEvent]) -> String {
        let subject = plan.subjectPlural
        let single = plan.subjectSingular
        guard let latest = results.first else {
            return "No \(subject) \(plan.rangeLabel)."
        }
        let count = results.count
        let camera = titleize(latest.camera)
        let when = relativeString(Date(timeIntervalSince1970: latest.startTime ?? 0))

        if plan.wantsLatest {
            return "The last \(single) was at \(camera), \(when)."
        }
        let noun = count == 1 ? single : subject
        return "Yes — \(count) \(noun) \(plan.rangeLabel). Most recent at \(camera), \(when)."
    }

    private static func relativeString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
