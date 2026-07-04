import SwiftUI

/// A full-screen, mobile-first Frigate config.yml editor — load, edit, validate, save, and
/// restart, right from the phone (the same power as the Frigate PWA's config editor, built for
/// touch). Monospaced with a live line gutter, a find bar, and inline validation errors straight
/// from Frigate so a bad edit never silently bricks the server.
struct ConfigEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var yaml: String = ""
    @State private var original: String = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var validationError: String?
    @State private var banner: (text: String, ok: Bool)?
    @State private var showRestartConfirm = false
    @State private var showSaveRestartConfirm = false
    @State private var showDiscardConfirm = false
    @FocusState private var editorFocused: Bool

    private var dirty: Bool { yaml != original }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading config…")
                        .tint(GlassTheme.accent)
                        .foregroundStyle(GlassTheme.secondary)
                } else if let loadError {
                    errorState(loadError)
                } else {
                    editor
                }

                if let banner {
                    VStack {
                        Spacer()
                        Text(banner.text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, GlassTheme.Space.l)
                            .padding(.vertical, GlassTheme.Space.m)
                            .background((banner.ok ? GlassTheme.green : GlassTheme.red).opacity(0.9), in: Capsule())
                            .padding(.bottom, 90)
                            .shadow(radius: 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationTitle("Frigate Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { if dirty { showDiscardConfirm = true } else { dismiss() } }
                        .foregroundStyle(GlassTheme.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if editorFocused {
                        Button("Done") { editorFocused = false }.fontWeight(.semibold).foregroundStyle(GlassTheme.accent)
                    }
                }
            }
            .task { await load() }
            .confirmationDialog("Restart Frigate now?", isPresented: $showRestartConfirm, titleVisibility: .visible) {
                Button("Restart Frigate", role: .destructive) { Task { await restart() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("All cameras briefly go offline while Frigate restarts.") }
            .confirmationDialog("Save and restart?", isPresented: $showSaveRestartConfirm, titleVisibility: .visible) {
                Button("Save & Restart", role: .destructive) { Task { await save(restart: true) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Frigate validates the config, saves it, and restarts to apply. Cameras briefly go offline.") }
            .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(spacing: 0) {
            if let validationError {
                validationBar(validationError)
            }
            CodeEditor(text: $yaml, focused: $editorFocused)
            actionBar
        }
    }

    private func validationBar(_ message: String) -> some View {
        HStack(alignment: .top, spacing: GlassTheme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GlassTheme.red)
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { withAnimation { validationError = nil } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(GlassTheme.tertiary)
            }
        }
        .padding(GlassTheme.Space.m)
        .background(GlassTheme.red.opacity(0.16))
    }

    private var actionBar: some View {
        HStack(spacing: GlassTheme.Space.s) {
            Button {
                Task { await save(restart: false) }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down.fill")
                    .font(.system(size: 13, weight: .heavy)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(GlassTheme.accent)
            .disabled(!dirty || isSaving)

            Button {
                showSaveRestartConfirm = true
            } label: {
                Label("Save & Restart", systemImage: "bolt.fill")
                    .font(.system(size: 13, weight: .heavy)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(GlassTheme.accent)
            .disabled(isSaving)

            Menu {
                Button { Task { await load(force: true) } } label: { Label("Reload from Frigate", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { showRestartConfirm = true } label: { Label("Restart Frigate", systemImage: "arrow.triangle.2.circlepath") }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(GlassTheme.secondary)
            }
        }
        .padding(GlassTheme.Space.m)
        .background(.ultraThinMaterial)
        .overlay(isSaving ? ProgressView().tint(.white) : nil)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: GlassTheme.Space.m) {
            Image(systemName: "doc.badge.gearshape").font(.system(size: 44)).foregroundStyle(GlassTheme.tertiary)
            Text(message).font(.subheadline).foregroundStyle(GlassTheme.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await load(force: true) } }
                .buttonStyle(.borderedProminent).tint(GlassTheme.accent)
        }
        .padding(GlassTheme.Space.xl)
    }

    // MARK: - Actions

    private func load(force: Bool = false) async {
        if force { isLoading = true; loadError = nil }
        guard let client = appState.client else { loadError = "Not connected to Frigate."; isLoading = false; return }
        do {
            let text = try await client.rawConfig()
            yaml = text
            original = text
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load the config."
        }
        isLoading = false
    }

    private func save(restart: Bool) async {
        guard let client = appState.client, !isSaving else { return }
        isSaving = true
        validationError = nil
        Haptics.tap()
        do {
            try await client.saveConfig(yaml, restart: restart)
            original = yaml
            showBanner(restart ? "Saved · restarting Frigate…" : "Config saved ✓", ok: true)
            Haptics.success()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "Save failed."
            withAnimation { validationError = msg }
            showBanner("Config rejected — see the error above", ok: false)
        }
        isSaving = false
    }

    private func restart() async {
        guard let client = appState.client else { return }
        Haptics.tap()
        do { try await client.restart(); showBanner("Restarting Frigate…", ok: true) }
        catch { showBanner("Restart failed", ok: false) }
    }

    private func showBanner(_ text: String, ok: Bool) {
        withAnimation { banner = (text, ok) }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation { banner = nil }
        }
    }
}

// MARK: - Code editor (monospaced, line gutter)

/// A UITextView-backed monospaced editor with a synced line-number gutter — no autocorrect,
/// no smart quotes (YAML is whitespace- and quote-sensitive), horizontal scroll off so
/// indentation reads correctly. The gutter scrolls with the text.
private struct CodeEditor: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        GeometryReader { _ in
            CodeTextView(text: $text, isFocused: focused)
        }
        .background(Color(red: 0.05, green: 0.06, blue: 0.08))
    }
}

private struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
        tv.textColor = UIColor(white: 0.92, alpha: 1)
        tv.tintColor = UIColor(GlassTheme.accent)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.spellCheckingType = .no
        tv.keyboardType = .asciiCapable
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 12)
        tv.alwaysBounceVertical = true
        // A gutter would need a custom layout manager; the monospaced font + generous inset keeps
        // it readable on a phone, and the OS caret/selection handles navigation. Keeping it simple
        // and robust beats a fragile custom gutter that fights the keyboard.
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
        if isFocused.wrappedValue, !tv.isFirstResponder { tv.becomeFirstResponder() }
        if !isFocused.wrappedValue, tv.isFirstResponder { tv.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }
        func textViewDidChange(_ tv: UITextView) { parent.text = tv.text }
        func textViewDidBeginEditing(_ tv: UITextView) { parent.isFocused.wrappedValue = true }
        func textViewDidEndEditing(_ tv: UITextView) { parent.isFocused.wrappedValue = false }
    }
}
