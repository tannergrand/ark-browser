import SwiftUI

/// Review sheet for AI tab grouping.
///
/// Approval-first on purpose: tabs are a working set, and silently reshuffling
/// them would feel like losing your place. Every row can be unchecked, and
/// unchecked tabs stay exactly where they are.
struct OrganizeTabsSheet: View {
    @Environment(BrowserState.self) private var state
    @State private var groups: [TabOrganizer.ProposedGroup]

    init(proposal: TabOrganizer.Proposal) {
        _groups = State(initialValue: proposal.groups)
    }

    private var acceptedCount: Int {
        groups.filter(\.accepted).reduce(0) { $0 + $1.tabIDs.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($groups) { $group in
                        groupCard($group)
                    }
                    if let ungrouped = state.organizeProposal?.ungrouped, !ungrouped.isEmpty {
                        Text("\(ungrouped.count) tab\(ungrouped.count == 1 ? "" : "s") left ungrouped")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
                .padding(14)
            }

            Divider()
            footer
        }
        .frame(width: 480, height: 420)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Suggested groups").font(.system(size: 13, weight: .semibold))
                Text("Nothing moves until you apply. Unchecked tabs stay where they are.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    private func groupCard(_ group: Binding<TabOrganizer.ProposedGroup>) -> some View {
        let tabs = group.wrappedValue.tabIDs.compactMap { id in
            state.allTabs.first { $0.id == id }
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: group.accepted).labelsHidden()
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                // Editable: the model's name is a suggestion, not a verdict.
                TextField("Group name", text: group.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text("\(tabs.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(tabs) { tab in
                    HStack(spacing: 6) {
                        Favicon(host: tab.faviconHost).frame(width: 12, height: 12)
                        Text(tab.displayTitle)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Text(tab.webView.url?.host ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.leading, 26)
            .opacity(group.wrappedValue.accepted ? 1 : 0.4)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Text("\(acceptedCount) tab\(acceptedCount == 1 ? "" : "s") will move")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { state.dismissOrganizeProposal() }
                .keyboardShortcut(.cancelAction)
                .jellyPress()
            Button("Apply") {
                state.organizeProposal?.groups = groups
                state.applyOrganizeProposal()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(acceptedCount == 0)
        }
        .padding(12)
    }
}
