import SwiftUI

/// Downloads list, opened from the sidebar chip or ⌘⌥L.
struct DownloadsPanel: View {
    @Environment(BrowserState.self) private var state

    private var manager: DownloadManager { state.downloads }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 12, weight: .semibold))
                Spacer()
                if manager.items.contains(where: { $0.finished || $0.failure != nil }) {
                    Button("Clear") { manager.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button { state.showDownloads = false } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().opacity(0.4)

            if manager.items.isEmpty {
                Text("Nothing downloaded yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(manager.items) { item in
                            row(item)
                            Divider().opacity(0.25)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 340)
        .glassSurface(.floating, in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                      enabled: state.glassChrome, intensity: state.glassIntensity)
        .glassRim(cornerRadius: 12, enabled: state.glassChrome, intensity: state.glassIntensity)
        .shadow(radius: 20, y: 8)
    }

    private func row(_ item: DownloadManager.Item) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.failure != nil ? "exclamationmark.triangle.fill"
                            : item.finished ? "doc.fill" : "arrow.down.circle")
                .foregroundStyle(item.failure != nil ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !item.finished && item.failure == nil {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                }
            }

            Spacer(minLength: 4)

            if item.finished {
                Button { manager.reveal(item) } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
