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
    @State private var showFind = false
    @State private var findQuery = ""
    /// Bumped to tell the editor to jump to the next match.
    @State private var findNext = 0
    @State private var fontSize: CGFloat = 13
    @FocusState private var editorFocused: Bool

    private var dirty: Bool { yaml != original }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassTheme.background.ignoresSafeArea()

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
                    } else if !isLoading, loadError == nil {
                        Menu {
                            Button { copyAll() } label: { Label("Copy whole config", systemImage: "doc.on.doc") }
                            Button { withAnimation { showFind.toggle() } } label: { Label(showFind ? "Hide Find" : "Find…", systemImage: "magnifyingglass") }
                            Menu {
                                Button { fontSize = min(20, fontSize + 1) } label: { Label("Bigger text", systemImage: "textformat.size.larger") }
                                Button { fontSize = max(10, fontSize - 1) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                            } label: { Label("Text size", systemImage: "textformat.size") }
                            Divider()
                            Button { Task { await load(force: true) } } label: { Label("Reload from Frigate", systemImage: "arrow.clockwise") }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(GlassTheme.accent)
                                .accessibilityLabel("Editor options")
                        }
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
            if showFind {
                findBar
            }
            CodeTextView(
                text: $yaml,
                fontSize: fontSize,
                findQuery: showFind ? findQuery : "",
                findNext: findNext,
                isFocused: $editorFocused
            )
            .background(Color(red: 0.05, green: 0.06, blue: 0.08))
            actionBar
        }
    }

    private var findBar: some View {
        HStack(spacing: GlassTheme.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(GlassTheme.tertiary)
            TextField("Find in config", text: $findQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.white)
                .submitLabel(.search)
                .onSubmit { findNext += 1 }
            Button { findNext += 1 } label: {
                Image(systemName: "chevron.down.circle.fill").foregroundStyle(GlassTheme.accent)
            }
            .accessibilityLabel("Find next")
            .disabled(findQuery.isEmpty)
            Button { withAnimation { showFind = false; findQuery = "" } } label: {
                Text("Done").font(.subheadline.weight(.semibold)).foregroundStyle(GlassTheme.accent)
            }
        }
        .padding(GlassTheme.Space.m)
        .background(.ultraThinMaterial)
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
            .accessibilityLabel("Dismiss error")
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
                    .accessibilityLabel("More actions")
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

    private func copyAll() {
        UIPasteboard.general.string = yaml
        Haptics.tap()
        showBanner("Whole config copied ✓", ok: true)
    }

    private func showBanner(_ text: String, ok: Bool) {
        withAnimation { banner = (text, ok) }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation { banner = nil }
        }
    }
}

// MARK: - Code editor

/// A real code editor for YAML on iPhone: syntax highlighting, a line-number gutter, a YAML
/// keyboard toolbar (indent / dedent / : / - / #), find-and-scroll, and adjustable text size.
/// Autocorrect / smart quotes / smart dashes OFF — YAML is whitespace- and quote-sensitive.
private struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var findQuery: String
    var findNext: Int
    var isFocused: FocusState<Bool>.Binding

    func makeUIView(context: Context) -> GutterTextView {
        let tv = GutterTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
        tv.tintColor = UIColor(GlassTheme.accent)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.keyboardType = .asciiCapable
        tv.keyboardAppearance = .dark
        tv.alwaysBounceVertical = true
        tv.textContainer.lineBreakMode = .byCharWrapping
        context.coordinator.textView = tv
        tv.inputAccessoryView = context.coordinator.makeToolbar()
        context.coordinator.apply(text: text, fontSize: fontSize, force: true)
        return tv
    }

    func updateUIView(_ tv: GutterTextView, context: Context) {
        if tv.text != text {
            context.coordinator.apply(text: text, fontSize: fontSize, force: true)
        } else if tv.font?.pointSize != fontSize {
            context.coordinator.apply(text: text, fontSize: fontSize, force: true)
        }
        if context.coordinator.lastFindNext != findNext {
            context.coordinator.lastFindNext = findNext
            context.coordinator.findAndScroll(findQuery)
        }
        if isFocused.wrappedValue, !tv.isFirstResponder { tv.becomeFirstResponder() }
        if !isFocused.wrappedValue, tv.isFirstResponder { tv.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: CodeTextView
        weak var textView: GutterTextView?
        var lastFindNext = 0
        private var fontSize: CGFloat = 13
        private var lastFoundLocation = 0

        init(_ parent: CodeTextView) { self.parent = parent; super.init() }

        /// Set the whole text (highlighted); called on load and font change.
        func apply(text: String, fontSize: CGFloat, force: Bool) {
            guard let tv = textView else { return }
            self.fontSize = fontSize
            let selected = tv.selectedRange
            tv.attributedText = YAMLHighlighter.highlight(text, fontSize: fontSize)
            if force { tv.selectedRange = NSRange(location: min(selected.location, (tv.text as NSString).length), length: 0) }
            tv.setNeedsDisplay()
        }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            (tv as? GutterTextView)?.setNeedsDisplay()
            // Re-color IN PLACE on the text storage — never replace attributedText mid-edit
            // (that jumps the caret and drops marked text). This keeps typing smooth and the
            // colors live. ~500 lines is well within a per-keystroke budget.
            let store = tv.textStorage
            store.beginEditing()
            YAMLHighlighter.apply(to: store, fontSize: fontSize)
            store.endEditing()
        }

        func textViewDidBeginEditing(_ tv: UITextView) { parent.isFocused.wrappedValue = true }
        func textViewDidEndEditing(_ tv: UITextView) { parent.isFocused.wrappedValue = false }

        // MARK: Find
        func findAndScroll(_ query: String) {
            guard let tv = textView, !query.isEmpty else { return }
            let ns = tv.text as NSString
            let start = min(lastFoundLocation + 1, ns.length)
            var range = ns.range(of: query, options: [.caseInsensitive], range: NSRange(location: start, length: ns.length - start))
            if range.location == NSNotFound {
                range = ns.range(of: query, options: [.caseInsensitive])   // wrap to top
            }
            guard range.location != NSNotFound else { return }
            lastFoundLocation = range.location
            tv.selectedRange = range
            tv.scrollRangeToVisible(range)
            Haptics.tap()
        }

        // MARK: Keyboard toolbar
        func makeToolbar() -> UIToolbar {
            let bar = UIToolbar()
            bar.barStyle = .black
            bar.sizeToFit()
            func item(_ title: String, _ sel: Selector) -> UIBarButtonItem {
                UIBarButtonItem(title: title, style: .plain, target: self, action: sel)
            }
            bar.items = [
                item("⇥", #selector(indent)),
                item("⇤", #selector(dedent)),
                .fixedSpace(8),
                item(":", #selector(insColon)),
                item("-", #selector(insDash)),
                item("#", #selector(insHash)),
                .flexibleSpace(),
                UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissKeyboard))
            ]
            bar.tintColor = UIColor(GlassTheme.accent)
            return bar
        }

        private func insert(_ s: String) {
            guard let tv = textView else { return }
            tv.insertText(s)
        }
        @objc private func indent() { insert("  ") }
        @objc private func insColon() { insert(": ") }
        @objc private func insDash() { insert("- ") }
        @objc private func insHash() { insert("# ") }
        @objc private func dismissKeyboard() { textView?.resignFirstResponder() }
        @objc private func dedent() {
            guard let tv = textView else { return }
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: tv.selectedRange)
            let line = ns.substring(with: lineRange)
            guard line.hasPrefix("  ") || line.hasPrefix(" ") else { return }
            let removed = line.hasPrefix("  ") ? 2 : 1
            let caret = tv.selectedRange
            let newLine = String(line.dropFirst(removed))
            tv.textStorage.replaceCharacters(in: lineRange, with: YAMLHighlighter.highlight(newLine, fontSize: fontSize))
            parent.text = tv.text
            tv.selectedRange = NSRange(location: max(lineRange.location, caret.location - removed), length: 0)
        }
    }
}

/// UITextView that draws a line-number gutter in its left inset, synced to the text scroll.
final class GutterTextView: UITextView {
    private let gutterWidth: CGFloat = 42
    private let gutterColor = UIColor(white: 0.4, alpha: 1)

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textContainerInset = UIEdgeInsets(top: 12, left: gutterWidth, bottom: 12, right: 12)
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        // Separator line for the gutter.
        if let ctx = UIGraphicsGetCurrentContext() {
            ctx.setStrokeColor(UIColor(white: 1, alpha: 0.06).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: gutterWidth - 4, y: rect.minY))
            ctx.addLine(to: CGPoint(x: gutterWidth - 4, y: rect.maxY))
            ctx.strokePath()
        }
        super.draw(rect)

        let ns = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: max(9, (font?.pointSize ?? 13) - 2), weight: .regular),
            .foregroundColor: gutterColor
        ]
        var lineNumber = 1
        // Draw a number at the start of each logical line that's within the visible rect.
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { [weak self] _, lineRange, _, _ in
            guard let self else { return }
            let glyphRange = self.layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var frag = self.layoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textContainer)
            frag.origin.y += self.textContainerInset.top
            if frag.intersects(rect) {
                let s = "\(lineNumber)" as NSString
                let size = s.size(withAttributes: attrs)
                s.draw(at: CGPoint(x: self.gutterWidth - 8 - size.width, y: frag.minY + 1), withAttributes: attrs)
            }
            lineNumber += 1
        }
    }
}

// MARK: - YAML syntax highlighting

private enum YAMLHighlighter {
    private static let base = UIColor(white: 0.90, alpha: 1)
    private static let keyColor = UIColor(red: 0.40, green: 0.78, blue: 1.0, alpha: 1)     // blue keys
    private static let commentColor = UIColor(white: 0.42, alpha: 1)                        // gray comments
    private static let stringColor = UIColor(red: 0.60, green: 0.86, blue: 0.55, alpha: 1)  // green strings
    private static let numberColor = UIColor(red: 0.85, green: 0.66, blue: 1.0, alpha: 1)   // purple numbers
    private static let boolColor = UIColor(red: 1.0, green: 0.68, blue: 0.35, alpha: 1)     // orange bool
    private static let dashColor = UIColor(red: 1.0, green: 0.45, blue: 0.55, alpha: 1)     // pink list dash

    static func highlight(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        apply(to: result, fontSize: fontSize)
        return result
    }

    /// Color an existing string in place (for live editing via `NSTextStorage`).
    static func apply(to storage: NSMutableAttributedString, fontSize: CGFloat) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let text = storage.string
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.setAttributes([.font: font, .foregroundColor: base], range: full)

        func color(_ pattern: String, _ ucolor: UIColor, group: Int = 0) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            re.enumerateMatches(in: text, range: full) { m, _, _ in
                if let m, m.numberOfRanges > group, m.range(at: group).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: ucolor, range: m.range(at: group))
                }
            }
        }

        color("^\\s*(-\\s*)?([A-Za-z0-9_./-]+)\\s*:", keyColor, group: 2)   // keys
        color("^\\s*(-)\\s", dashColor, group: 1)                            // list dash
        color("\"[^\"]*\"|'[^']*'", stringColor)                             // quoted strings
        color("\\b(true|false|yes|no|null|on|off)\\b", boolColor)            // booleans/null
        color(":\\s*(-?\\d+(?:\\.\\d+)?)\\b", numberColor, group: 1)         // numeric values
        color("#[^\\n]*", commentColor)                                      // comments (wins last)
    }
}
