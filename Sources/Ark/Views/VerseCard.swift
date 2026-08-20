import SwiftUI

/// The verse card on a blank tab. Quiet by design — it sits on the colour field
/// and doesn't compete with the command bar.
struct VerseCard: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        Group {
            if let verse = state.verse {
                content(verse)
                    .transition(Motion.appear)
            }
        }
        .animation(Motion.jelly, value: state.verse?.reference)
    }

    private func content(_ verse: VerseSuggestion.Verse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.system(size: 10))
                Text(verse.reference)
                    .font(.system(size: 12, weight: .semibold))
                if !verse.translation.isEmpty {
                    Text(verse.translation)
                        .font(.system(size: 10))
                        .opacity(0.55)
                }
            }
            .foregroundStyle(.white.opacity(0.85))

            if verse.text.isEmpty {
                // The lookup failed. Say so rather than filling the gap with
                // something the model produced.
                Text("Couldn't load the text — open it to read it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Text(verse.text)
                    .font(.system(size: 16, weight: .regular, design: .serif))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }

            if !verse.connection.isEmpty {
                Text(verse.connection)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }

            HStack(spacing: 10) {
                if let url = verse.bibleComURL {
                    Button {
                        state.focusedTab?.load(url)
                    } label: {
                        Text("Read on Bible.com")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                }
                Button {
                    Task { await state.refreshVerse(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(JellyPress(scale: 0.85))
                .foregroundStyle(.white.opacity(0.6))
                .help("Suggest another")
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.black.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .glassRim(cornerRadius: 14, enabled: state.glassChrome,
                  intensity: state.glassIntensity)
    }
}
