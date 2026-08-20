import SwiftUI

/// Inline credential menu, anchored under the login field the page has focused —
/// the same shape a password-manager extension shows, but native, since WebKit
/// has no extension system to host one.
struct AutofillPopover: View {
    @Environment(BrowserState.self) private var state
    let tab: BrowserTab
    let candidates: [PasswordManager.Candidate]
    @State private var hovered: String?
    @State private var filling: String?

    private var manager: PasswordManager { state.passwords }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            ForEach(candidates) { candidate in
                row(candidate)
            }
        }
        .padding(4)
        .frame(minWidth: 240, maxWidth: 320, alignment: .leading)
        .glassSurface(.floating, in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                      enabled: state.glassChrome, intensity: state.glassIntensity)
        .glassRim(cornerRadius: 9, enabled: state.glassChrome, intensity: state.glassIntensity)
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        // The page blurs its field the moment this is clicked, so hovering has
        // to cancel the pending dismissal or the menu vanishes mid-click.
        .onHover { inside in
            if inside { manager.cancelAutofillDismiss() }
            else { manager.scheduleAutofillDismiss(for: tab) }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "key.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(tab.autofillKind == "password" ? "Fill password" : "Fill login")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if manager.source == .onePassword, manager.opUnlocked == false {
                Label("1Password locked", systemImage: "lock.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.orange)
            }
            Button {
                tab.autofillAnchor = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 3)
        .padding(.bottom, 2)
    }

    private func row(_ candidate: PasswordManager.Candidate) -> some View {
        Button {
            filling = candidate.id
            Task {
                await manager.fill(candidate: candidate, into: tab)
                await MainActor.run { filling = nil }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: candidate.origin == .onePassword ? "lock.shield.fill" : "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(candidate.origin == .onePassword
                                     ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.secondary))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 0) {
                    Text(candidate.label.isEmpty ? candidate.domain : candidate.label)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(candidate.sublabel)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if filling == candidate.id {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                } else if candidate.origin == .drift && manager.requireBiometrics && !manager.isUnlocked {
                    Image(systemName: PasswordManager.biometricsAvailable ? "touchid" : "lock")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered == candidate.id ? Color.accentColor.opacity(0.16) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(JellyPress(scale: 0.97))
        .onHover { hovered = $0 ? candidate.id : nil }
        .disabled(filling != nil)
    }
}
