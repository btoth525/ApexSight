import SwiftUI

/// Settings › Video Feeds: the list the car chooses from. Add every Frigate camera in one tap, or
/// any HLS / MP4 / MJPEG / H.264 URL by hand; play on the phone (with PiP) or send to the car.
struct FeedsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var session = CarVideoSession.shared
    @State private var editing: FeedDraft?
    @State private var playing: Feed?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(spacing: GlassTheme.Space.l) {
                    statusCard
                    feedsCard
                    addCard
                }
                .padding(GlassTheme.Space.l)
            }
        }
        .navigationTitle("Video Feeds")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .sheet(item: $editing) { draft in FeedEditor(draft: draft) { saved in commit(saved) } }
        .fullScreenCover(item: $playing) { feed in FeedPlayerScreen(feed: feed) }
        .overlay(alignment: .bottom) { if let toast { GlassToast(text: toast) } }
    }

    // MARK: - Cards

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Now playing", subtitle: statusLine)
                HStack(spacing: GlassTheme.Space.m) {
                    Button {
                        Haptics.tap()
                        CarVideoSession.shared.startMirror()
                        show("Tap Start Broadcast on the sheet")
                    } label: {
                        Label("Mirror to Car", systemImage: "iphone.and.arrow.forward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle())
                    Button {
                        Haptics.tap()
                        CarVideoSession.shared.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(session.source == .none)
                }
                Text("Full-screen video on the car needs the CarPlay navigation entitlement. Without it, the car shows each feed as a picture that refreshes about once a second.")
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.tertiary)
            }
        }
    }

    private var statusLine: String {
        switch session.source {
        case .none: return "Nothing playing"
        case .mirror: return "Phone screen mirror · \(stateText)"
        case .feed(let feed): return "\(feed.name) · \(stateText)"
        }
    }

    private var stateText: String {
        switch session.state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .streaming: return "live"
        case .failed(let message): return message
        }
    }

    private var feedsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Feeds", subtitle: store.feeds.isEmpty ? "None yet" : "\(store.feeds.count) configured")
                if store.feeds.isEmpty {
                    Text("Add your Frigate cameras below, or any stream URL.")
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                }
                ForEach(store.feeds) { feed in
                    feedRow(feed)
                    if feed.id != store.feeds.last?.id { Divider().overlay(GlassTheme.separator) }
                }
            }
        }
    }

    private func feedRow(_ feed: Feed) -> some View {
        HStack(spacing: GlassTheme.Space.m) {
            Button {
                Haptics.tap()
                playing = feed
            } label: {
                HStack(spacing: GlassTheme.Space.m) {
                    Image(systemName: feed.kind.usesAVPlayer ? "play.rectangle.fill" : "dot.radiowaves.left.and.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.name).font(.headline).foregroundStyle(GlassTheme.primary).lineLimit(1)
                        Text("\(feed.kind.title) · \(feed.url.host() ?? feed.url.absoluteString)")
                            .font(.footnote).foregroundStyle(GlassTheme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(feed.name)")
            Menu {
                Button { editing = FeedDraft(feed: feed) } label: { Label("Edit", systemImage: "pencil") }
                Button { CarVideoSession.shared.play(feed); show("Playing on the car") } label: {
                    Label("Play on Car", systemImage: "car.fill")
                }
                Button(role: .destructive) { store.remove(feed) } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(GlassTheme.secondary)
                    .hitTarget()
            }
            .accessibilityLabel("\(feed.name) options")
        }
    }

    private var addCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Add")
                Button {
                    Haptics.tap()
                    guard let client = appState.client else { show("Sign in to Frigate first"); return }
                    let added = store.addFrigateCameras(appState.cameras.map(\.name), client: client)
                    show(added == 0 ? "All cameras already added" : "Added \(added) camera\(added == 1 ? "" : "s")")
                } label: {
                    Label("Add Frigate cameras", systemImage: "video.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle())
                Button {
                    Haptics.tap()
                    editing = FeedDraft()
                } label: {
                    Label("Add a URL", systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
    }

    // MARK: - Helpers

    private func commit(_ draft: FeedDraft) {
        guard let feed = draft.feed else { return }
        if store.feeds.contains(where: { $0.id == feed.id }) { store.update(feed) } else { store.add(feed) }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { if toast == message { toast = nil } }
        }
    }
}

// MARK: - Editor

struct FeedDraft: Identifiable {
    var id = UUID()
    var name = ""
    var urlText = ""
    var kind: Feed.Kind?
    var usesFrigateAuth = false

    init() {}
    init(feed: Feed) {
        id = feed.id
        name = feed.name
        urlText = feed.url.absoluteString
        kind = feed.kind
        usesFrigateAuth = feed.usesFrigateAuth
    }

    var url: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    var feed: Feed? {
        guard let url, let kind else { return nil }
        let title = name.trimmingCharacters(in: .whitespaces)
        return Feed(id: id, name: title.isEmpty ? (url.host() ?? "Feed") : title, url: url, kind: kind, usesFrigateAuth: usesFrigateAuth)
    }
}

private struct FeedEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: FeedDraft
    let onSave: (FeedDraft) -> Void
    @FocusState private var focus: Field?
    private enum Field { case name, url }

    var body: some View {
        NavigationStack {
            Form {
                Section("Feed") {
                    TextField("Name", text: $draft.name)
                        .textContentType(.name)
                        .submitLabel(.next)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .url }
                    TextField("https://host/live/index.m3u8", text: $draft.urlText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focus, equals: .url)
                        .onChange(of: draft.urlText) { _, text in
                            if draft.kind == nil, let url = URL(string: text) { draft.kind = Feed.detectKind(from: url) }
                        }
                    if let url = draft.url, let message = Feed.unsupportedSchemeMessage(for: url) {
                        Text(message).font(.footnote).foregroundStyle(GlassTheme.orange)
                    }
                }
                Section("Type") {
                    Picker("Type", selection: $draft.kind) {
                        Text("Choose…").tag(Feed.Kind?.none)
                        ForEach(Feed.Kind.allCases) { kind in Text(kind.title).tag(Feed.Kind?.some(kind)) }
                    }
                    .pickerStyle(.menu)
                    Toggle("Sign with Frigate login", isOn: $draft.usesFrigateAuth)
                }
            }
            .navigationTitle(draft.name.isEmpty ? "Feed" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }
                        .disabled(draft.feed == nil || Feed.unsupportedSchemeMessage(for: draft.url ?? URL(fileURLWithPath: "/")) != nil)
                }
            }
            .onAppear { focus = draft.name.isEmpty ? .name : nil }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Player screen

private struct FeedPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = CarVideoSession.shared
    let feed: Feed

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            PhoneVideoView().ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    .padding()
                }
                Spacer()
                statusPill
                    .padding(.bottom, 24)
            }
        }
        .task { CarVideoSession.shared.play(feed) }
        .statusBarHidden()
    }

    @ViewBuilder
    private var statusPill: some View {
        switch session.state {
        case .streaming: EmptyView()
        case .connecting: pill("Connecting…", icon: "dot.radiowaves.left.and.right")
        case .idle: pill("Stopped", icon: "pause.fill")
        case .failed(let message): pill(message, icon: "wifi.exclamationmark")
        }
    }

    private func pill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.vertical, GlassTheme.Space.s)
            .liquidGlass(in: Capsule(), interactive: false, fallbackMaterial: .ultraThinMaterial)
    }
}
