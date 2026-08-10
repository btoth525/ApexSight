import SwiftUI

/// Frigate 0.18's GenAI **review summary**, rendered as the story of what happened.
///
/// This is a different thing from the per-object description card (`aiCard` in ReviewDetailView),
/// and the two are easy to confuse. The object description answers *"who was that"* — "a woman in
/// a black t-shirt carrying a box". This answers *"should I care about this one"*: a headline, a
/// one-line summary, a beat-by-beat account, and Frigate's own threat rating.
///
/// Design intent: the level badge and headline carry the whole thing at a glance, because that is
/// all you want while thumbing past an alert at the door. The blow-by-blow is collapsed by
/// default — it's genuinely interesting after the fact and pure noise in the moment.
struct ReviewStoryCard: View {
    let summary: ReviewAISummary
    /// The review's tracked objects — needed because a recognised person (`person-verified`)
    /// invalidates an escalation no matter what the model wrote. See `ThreatLevel.trusted`.
    var objects: [String] = []
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Nil = the rating isn't believable, so the card shows the story WITHOUT a verdict rather
    /// than inventing a reassuring one.
    private var level: ThreatLevel? {
        ThreatLevel.trusted(raw: summary.potentialThreatLevel,
                            confidence: summary.confidence,
                            objects: objects)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                header

                if let headline = summary.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.headline)
                        .foregroundStyle(GlassTheme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Only show the one-liner when it isn't already doing duty as the headline.
                // `summarySentence`, not `shortSummary` — Frigate clamps that one to 140 chars
                // mid-word on about a third of reviews (see the doc on summarySentence).
                if let short = summary.summarySentence, !short.isEmpty,
                   short != summary.headline {
                    Text(short)
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let concerns = (summary.otherConcerns ?? [])
                    .map(\.trimmed).filter { !$0.isEmpty }
                if !concerns.isEmpty {
                    concernRow(concerns.joined(separator: " · "))
                }

                if hasDetail {
                    disclosure
                    if expanded { detail }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: GlassTheme.Space.s) {
            Image(systemName: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GlassTheme.accent)
            Text("What happened")
                .font(.headline)
                .foregroundStyle(GlassTheme.primary)
            Spacer(minLength: GlassTheme.Space.s)
            levelBadge
        }
        // One label for the pair so VoiceOver reads "What happened, Routine" rather than
        // stopping on a bare icon — same grouping the review/camera rows already use.
        .accessibilityElement(children: .combine)
    }

    /// No badge when the rating isn't believable. Showing "Routine" there would be worse than
    /// showing nothing: it's an affirmative all-clear the model never actually gave.
    @ViewBuilder
    private var levelBadge: some View {
        if let level {
            HStack(spacing: 4) {
                Image(systemName: level.symbol)
                    .font(.caption2.weight(.bold))
                Text(level.label)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(level.tint)
            .padding(.horizontal, GlassTheme.Space.s)
            .padding(.vertical, 4)
            .background(level.tint.opacity(0.14), in: Capsule())
            // Never colour-only: the symbol and the word both carry the meaning.
            .overlay(Capsule().stroke(level.tint.opacity(0.35), lineWidth: 1))
        }
    }

    private func concernRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: GlassTheme.Space.s) {
            Image(systemName: "flag.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GlassTheme.orange)
            Text(text)
                .font(.footnote)
                .foregroundStyle(GlassTheme.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GlassTheme.Space.s)
        .background(GlassTheme.orange.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Flagged concern. \(text)")
    }

    private var hasDetail: Bool {
        !(summary.observations ?? []).isEmpty || !(summary.scene?.trimmed ?? "").isEmpty
    }

    private var disclosure: some View {
        Button {
            Haptics.tap()
            if reduceMotion { expanded.toggle() }
            else { withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { expanded.toggle() } }
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? "Hide the play-by-play" : "Show the play-by-play")
                    .font(.footnote.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .foregroundStyle(GlassTheme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 44pt hit target — the label alone is far shorter than a comfortable tap.
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "Collapses the step-by-step account" : "Expands the step-by-step account")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
            if let obs = summary.observations, !obs.isEmpty {
                VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                    ForEach(Array(obs.enumerated()), id: \.offset) { index, line in
                        observationRow(index: index, text: line, isLast: index == obs.count - 1)
                    }
                }
            }

            // `summarySentence` now usually IS `scene` (it's the field that isn't clamped), so
            // without this the same paragraph rendered twice — once as the one-liner above and
            // again inside the play-by-play.
            if let scene = summary.scene?.trimmed, !scene.isEmpty,
               scene != summary.headline, scene != summary.summarySentence {
                Text(scene)
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footnote
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }

    /// A timeline beat: a connected rail of dots so the observations read in order rather than as
    /// an undifferentiated bullet list.
    private func observationRow(index: Int, text: String, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: GlassTheme.Space.s) {
            VStack(spacing: 0) {
                Circle()
                    .fill(GlassTheme.accent.opacity(0.85))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                if !isLast {
                    Rectangle()
                        .fill(GlassTheme.separator)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 7)

            Text(text)
                .font(.footnote)
                .foregroundStyle(GlassTheme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, isLast ? 0 : GlassTheme.Space.xs)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(index + 1). \(text)")
    }

    /// Provenance, deliberately understated: this is a model's reading, not ground truth, and the
    /// card shouldn't imply more certainty than it has.
    @ViewBuilder
    private var footnote: some View {
        let confidence = summary.confidence.map { Int(($0 * 100).rounded()) }
        let bits = [summary.time?.trimmed,
                    confidence.map { "\($0)% confidence" }]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !bits.isEmpty {
            Text(bits.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(GlassTheme.secondary)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
