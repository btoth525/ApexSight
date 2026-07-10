import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Call strip (compact soundboard shown inside the doorbell call)

/// A compact talkback bar for the answered doorbell call: quick spoken replies, a Say… composer,
/// and a hold-to-talk button — all speak through the door via the relay.
struct DoorbellSoundboardStrip: View {
    @ObservedObject var soundboard: DoorbellSoundboard
    @StateObject private var recorder = DoorbellVoiceRecorder()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSay = false
    @State private var talkPulse = false

    var body: some View {
        VStack(spacing: GlassTheme.Space.s) {
            // Relay/talkback failures surface right in the call — a tap that made no sound at the
            // door must never be silent in the UI.
            if let status = soundboard.status {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, GlassTheme.Space.m)
                    .padding(.vertical, GlassTheme.Space.s)
                    .background(GlassTheme.red.opacity(0.8), in: Capsule())
                    .transition(.opacity)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: GlassTheme.Space.s) {
                    chip(icon: "text.bubble.fill", label: "Say…") { showSay = true }
                    ForEach(soundboard.clips) { clip in
                        chip(icon: "megaphone.fill", label: clip.name) {
                            Task { await soundboard.playClip(clip.slug) }
                        }
                    }
                    ForEach(DoorbellSmartReplies.presets.prefix(4), id: \.self) { reply in
                        chip(icon: "quote.bubble", label: reply) {
                            Task { await soundboard.say(reply) }
                        }
                    }
                }
                .padding(.horizontal, GlassTheme.Space.m)
            }

            talkButton
                .padding(.bottom, GlassTheme.Space.xs)
        }
        .opacity(soundboard.busy ? 0.7 : 1)
        .animation(.easeInOut(duration: 0.2), value: soundboard.status)
        .sheet(isPresented: $showSay) {
            DoorbellSayView(soundboard: soundboard)
        }
        // Call ended (remotely or locally) mid-hold: never leave a hot mic or a hijacked session.
        .onDisappear { recorder.stop() }
    }

    private var talkButton: some View {
        let recording = recorder.isRecording
        return VStack(spacing: 4) {
            Image(systemName: recording ? "waveform" : "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(recording ? GlassTheme.red : GlassTheme.accent, in: Circle())
                .scaleEffect(recording && !reduceMotion ? (talkPulse ? 1.08 : 1) : 1)
                .animation(recording && !reduceMotion ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : nil,
                           value: talkPulse)
            Text(recording ? "Release to send" : "Hold to Talk")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .contentShape(Circle())
        // `pressing:` (unlike a DragGesture) is ALSO called with false when the system cancels the
        // gesture (scroll steal, view teardown) — so the mic can never be left hot on a cancel.
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60) {} onPressingChanged: { pressing in
            if pressing {
                Haptics.tap()
                recorder.start()
                talkPulse = true
            } else {
                talkPulse = false
                guard let clip = recorder.stopAndData() else { return }
                Haptics.success()
                Task {
                    await soundboard.sendData(clip.data, filename: "talk.m4a")
                    try? FileManager.default.removeItem(at: clip.url)
                }
            }
        }
        .task { DoorbellVoiceRecorder.requestPermission() }
    }

    private func chip(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.footnote.weight(.semibold))
                Text(label).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, GlassTheme.Space.m)
            .padding(.vertical, GlassTheme.Space.s)
            .background(.white.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Say composer (type + on-device smart replies → speak)

/// Type text (or tap a preset / AI idea) and speak it at the door in an on-device voice.
struct DoorbellSayView: View {
    @ObservedObject var soundboard: DoorbellSoundboard
    @Environment(\.dismiss) private var dismiss
    @AppStorage("doorbellVoiceID") private var voiceID = ""
    @State private var text = ""
    @State private var saveIt = false
    @State private var saveName = ""
    @State private var aiSuggestions: [String] = []
    @State private var loadingAI = false
    @FocusState private var focused: Bool

    private let voices = DoorbellSpeech.selectableVoices()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    TextField("Type what to say at the door…", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .font(.title3)
                        .focused($focused)
                        .padding()
                        .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.card))

                    voicePicker

                    // Quick replies stay put — never mutated, so nothing shifts under your finger.
                    SectionHeader("Quick replies")
                    FlowChips(items: DoorbellSmartReplies.presets) { text = $0 }

                    // AI ideas load only when you ask, into their own section (no surprise reflow).
                    if DoorbellSmartReplies.modelAvailable {
                        HStack {
                            SectionHeader("AI ideas")
                            Spacer()
                            if loadingAI {
                                ProgressView().controlSize(.small)
                            } else {
                                Button { Task { await generateAI() } } label: {
                                    Label(aiSuggestions.isEmpty ? "Generate" : "Regenerate", systemImage: "sparkles")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                        if !aiSuggestions.isEmpty {
                            FlowChips(items: aiSuggestions) { text = $0 }
                                .transition(.opacity)
                        }
                    }

                    Toggle("Save as a soundboard button", isOn: $saveIt)
                        .tint(GlassTheme.accent)
                    if saveIt {
                        TextField("Button name (e.g. \"Leave package\")", text: $saveName)
                            .textFieldStyle(.roundedBorder)
                    }

                    if let status = soundboard.status {
                        Text(status).font(.footnote).foregroundStyle(GlassTheme.red)
                    }
                }
                .padding()
                .animation(.easeInOut(duration: 0.2), value: aiSuggestions)
            }
            .background(GlassTheme.background.ignoresSafeArea())
            .navigationTitle("Say at the Door")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speak") {
                        let toSay = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = saveIt ? saveName.trimmingCharacters(in: .whitespaces) : ""
                        Task { await soundboard.say(toSay, voiceID: voiceID.isEmpty ? nil : voiceID, saveAs: name) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || soundboard.busy)
                }
            }
            .task { focused = true }
        }
    }

    @ViewBuilder private var voicePicker: some View {
        if !voices.isEmpty {
            let current = DoorbellSpeech.voice(id: voiceID)
            HStack {
                Label("Voice", systemImage: "waveform")
                    .font(.subheadline).foregroundStyle(GlassTheme.secondary)
                Spacer()
                Menu {
                    ForEach(voices, id: \.identifier) { v in
                        Button {
                            voiceID = v.identifier
                        } label: {
                            if v.identifier == current?.identifier { Label("\(v.name) · \(DoorbellSpeech.qualityName(v.quality))", systemImage: "checkmark") }
                            else { Text("\(v.name) · \(DoorbellSpeech.qualityName(v.quality))") }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(current.map { "\($0.name) · \(DoorbellSpeech.qualityName($0.quality))" } ?? "Default")
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(GlassTheme.accent)
                }
            }
        }
    }

    private func generateAI() async {
        loadingAI = true
        defer { loadingAI = false }
        aiSuggestions = await DoorbellSmartReplies.suggestions()
    }
}

// MARK: - Management screen (Settings → Doorbell Talkback)

/// Manage the doorbell soundboard: see reachability, play/delete saved clips, add new ones by
/// speaking text, recording, or importing an audio file.
struct DoorbellSoundboardView: View {
    @StateObject private var soundboard = DoorbellSoundboard()
    @StateObject private var recorder = DoorbellVoiceRecorder()
    @State private var showSay = false
    @State private var importing = false

    var body: some View {
        List {
            Section {
                HStack {
                    Label("Doorbell speaker", systemImage: "megaphone.fill")
                    Spacer()
                    if !soundboard.checked {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(soundboard.available ? "Ready" : "Not reachable")
                            .foregroundStyle(soundboard.available ? GlassTheme.green : GlassTheme.secondary)
                    }
                }
                if soundboard.checked && !soundboard.available {
                    Text("Set `doorbell_ip` in the ApexSight Push add-on (1.10.0+) and make sure the doorbell is on the same network.")
                        .font(.footnote).foregroundStyle(GlassTheme.secondary)
                }
            }

            Section("Add") {
                Button { showSay = true } label: {
                    Label("Speak text (on-device voice)", systemImage: "text.bubble.fill")
                }
                Button { importing = true } label: {
                    Label("Import an audio file / MP3", systemImage: "square.and.arrow.down")
                }
                RecordRow(recorder: recorder, soundboard: soundboard)
            }

            if !soundboard.clips.isEmpty {
                Section("Soundboard") {
                    ForEach(soundboard.clips) { clip in
                        HStack {
                            Button { Task { await soundboard.playClip(clip.slug) } } label: {
                                Label(clip.name, systemImage: "play.circle.fill")
                            }
                            Spacer()
                        }
                        .swipeActions {
                            Button(role: .destructive) { Task { await soundboard.delete(clip.slug) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if let status = soundboard.status {
                Section { Text(status).font(.footnote).foregroundStyle(GlassTheme.red) }
            }
        }
        .navigationTitle("Doorbell Talkback")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSay) { DoorbellSayView(soundboard: soundboard) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav],
                      allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let name = url.deletingPathExtension().lastPathComponent
            Task {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    await soundboard.sendData(data, filename: url.lastPathComponent, saveAs: name)
                } else {
                    // iCloud Drive file not downloaded locally, or unreadable — say so.
                    soundboard.status = "Couldn't read that file — if it's in iCloud, download it in Files first."
                }
            }
        }
        .task { await soundboard.refresh() }
    }
}

/// A hold-to-record row that saves the recording as a named preset.
private struct RecordRow: View {
    @ObservedObject var recorder: DoorbellVoiceRecorder
    @ObservedObject var soundboard: DoorbellSoundboard

    var body: some View {
        HStack {
            Label(recorder.isRecording ? "Recording… release to save" : "Hold to record a clip",
                  systemImage: recorder.isRecording ? "waveform" : "mic.circle.fill")
                .foregroundStyle(recorder.isRecording ? GlassTheme.red : GlassTheme.primary)
            Spacer()
        }
        .contentShape(Rectangle())
        // `pressing:` gets false even when the List's scroll pan CANCELS the gesture — a plain
        // DragGesture's onEnded doesn't fire on cancel, which left the mic hot (and the eventual
        // release would have played the whole ambient recording at the front door).
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 40) {} onPressingChanged: { pressing in
            if pressing {
                Haptics.tap()
                recorder.start()
            } else {
                guard let clip = recorder.stopAndData() else { return }
                Haptics.success()
                Task {
                    let stamp = Int(Date().timeIntervalSince1970) % 100000
                    await soundboard.sendData(clip.data, filename: "rec.m4a", saveAs: "Clip \(stamp)")
                    try? FileManager.default.removeItem(at: clip.url)
                }
            }
        }
        .onDisappear { recorder.stop() }
        .task { DoorbellVoiceRecorder.requestPermission() }
    }
}

// MARK: - Small wrapping chip layout

/// A simple wrapping row of tappable suggestion chips.
private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
            ForEach(rows(), id: \.self) { row in
                HStack(spacing: GlassTheme.Space.s) {
                    ForEach(row, id: \.self) { item in
                        Button { Haptics.tap(); onTap(item) } label: {
                            Text(item)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, GlassTheme.Space.m)
                                .padding(.vertical, GlassTheme.Space.s)
                                .background(GlassTheme.surfaceHigh, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Naive greedy wrap by character count — good enough for short reply chips.
    private func rows() -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var width = 0
        for item in items {
            let w = item.count + 4
            if width + w > 42, !current.isEmpty {
                rows.append(current); current = []; width = 0
            }
            current.append(item); width += w
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}
