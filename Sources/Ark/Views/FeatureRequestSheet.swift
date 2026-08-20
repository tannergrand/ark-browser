import AppKit
import SwiftUI

/// The request form. Saves locally first, then offers to send it on.
struct FeatureRequestSheet: View {
    let done: () -> Void

    @State private var title = ""
    @State private var detail = ""
    @State private var saved = false
    @State private var error: String?

    private var request: FeatureRequest { FeatureRequest(title: title, detail: detail) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Request a feature")
                .font(.system(size: 16, weight: .semibold))
            Text("Saved on this Mac straight away, so it can't be lost. Sending it on is a separate, optional step.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("One line — what should Ark do?", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $detail)
                .font(.system(size: 12.5))
                .frame(height: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if detail.isEmpty {
                        Text("Any detail — what you were doing, what you expected.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            Text("Attached: Ark \(Updater.currentVersion) and your macOS version. Nothing else — no page, no URL, no history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if saved {
                Label("Saved. Send it on, or close — it's kept either way.",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }

            HStack {
                Button("Copy") {
                    save()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(request.asText, forType: .string)
                }
                .disabled(!request.isValid)
                Button("Open a GitHub Issue") {
                    save()
                    if let url = request.issueURL() { NSWorkspace.shared.open(url) }
                }
                .disabled(!request.isValid)
                Spacer()
                Button("Close", action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: { save(); done() })
                    .keyboardShortcut(.defaultAction)
                    .disabled(!request.isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Idempotent enough for the three buttons that call it: saving twice from
    /// one sheet writes one record, because the request keeps its id.
    private func save() {
        guard request.isValid, !saved else { return }
        do {
            try FeatureRequest.append(request)
            saved = true
            error = nil
        } catch {
            self.error = "Couldn't save locally: \(error.localizedDescription)"
        }
    }
}
