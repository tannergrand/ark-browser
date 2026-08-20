import SwiftUI

/// "Save this login?" prompt, shown after a login form is submitted.
struct SavePasswordBanner: View {
    @Environment(BrowserState.self) private var state
    let prompt: PasswordManager.SavePrompt

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(prompt.isUpdate
                     ? "Update the password for \(prompt.host)?"
                     : "Save this login for \(prompt.host)?")
                    .font(.system(size: 12, weight: .medium))
                Text("\(prompt.username) · saves to iCloud Keychain")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button("Not Now") { state.passwords.dismissSave() }
                .controlSize(.small)
                .jellyPress()
            Button(prompt.isUpdate ? "Update" : "Save") { state.passwords.confirmSave() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassSurface(.floating, in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                      enabled: state.glassChrome, intensity: state.glassIntensity)
        .glassRim(cornerRadius: 10, enabled: state.glassChrome, intensity: state.glassIntensity)
        .shadow(radius: 14, y: 5)
        .frame(maxWidth: 460)
    }
}

/// Small "fill login" affordance that appears when a page has a login form and
/// the vault holds a credential for it.
struct FillLoginChip: View {
    @Environment(BrowserState.self) private var state
    let tab: BrowserTab

    var body: some View {
        Button {
            Task {
                _ = await state.passwords.fill(into: tab)
                await MainActor.run { state.passwords.offerFillFor = nil }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: PasswordManager.biometricsAvailable ? "touchid" : "key.fill")
                Text("Fill login")
                Text("⌘⇧F").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassSurface(.control, in: Capsule(), enabled: state.glassChrome, intensity: state.glassIntensity)
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .jellyPress()
        .shadow(radius: 10, y: 3)
    }
}
