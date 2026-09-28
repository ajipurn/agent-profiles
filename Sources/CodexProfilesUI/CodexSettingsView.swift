import SwiftUI
import AgentUI
import CodexProfilesCore

/// Settings → Codex: saved accounts and what Codex Profiles' panel used to
/// offer (rename, favorites, remove, sign-in, options).
public struct CodexSettingsView: View {
    @Bindable var model: AppModel
    @State private var confirmingRemoval: Profile?
    @FocusState private var nameFocused: Bool

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            feedback
            if let editor = model.editor {
                nameEditor(editor)
            }
            if model.awaitingLogin {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in Terminal.")
                        Spacer()
                        Button("Cancel Sign-in") { model.cancelLogin() }
                    }
                }
            }
            Section("Current Account") {
                LabeledContent("Signed in as", value: model.currentTitle)
                if model.live?.identity != nil {
                    LabeledContent("Plan", value: model.currentSubtitle.isEmpty ? "–" : model.currentSubtitle)
                }
                if model.needsSave, model.editor == nil {
                    Button("Save Current Account…") { model.beginSave() }
                }
            }
            accounts
            Section("Options") {
                Toggle("Restart ChatGPT after switching", isOn: setting(\.restartChatGPT))
                Toggle("Refresh usage automatically", isOn: setting(\.autoRefresh))
                Toggle("Hide email addresses", isOn: setting(\.hideEmails))
                Picker("Sort accounts by", selection: setting(\.sortOrder)) {
                    ForEach(ProfileSortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove \(confirmingRemoval.map(model.displayName(for:)) ?? "this account")?",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            presenting: confirmingRemoval
        ) { profile in
            Button("Remove", role: .destructive) { model.delete(profile) }
        } message: { _ in
            Text("Its saved login is deleted. If it is the active account, Codex stays signed in.")
        }
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = model.error {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { model.dismissError() }
                }
            }
        } else if let status = model.status {
            Section {
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(status)
                }
            }
        }
    }

    private func nameEditor(_ editor: AppModel.EditorMode) -> some View {
        Section(editorTitle(editor)) {
            TextField("Account name", text: $model.draftName)
                .focused($nameFocused)
                .onSubmit { model.commitEditor() }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelEditor() }
                Button("Save") { model.commitEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            }
        }
        .onAppear { nameFocused = true }
    }

    private func editorTitle(_ editor: AppModel.EditorMode) -> String {
        switch editor {
        case .save: "Save the current account"
        case .add: "Name the new account"
        case .rename: "Rename account"
        }
    }

    private var accounts: some View {
        Section {
            if model.profiles.count > 5 {
                TextField("Search accounts", text: $model.searchText)
            }
            if model.profiles.isEmpty {
                Text("No saved accounts yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.visibleProfiles) { profile in
                row(profile)
            }
        } header: {
            Text("Accounts")
        } footer: {
            HStack {
                Spacer()
                Button("Add Account…") { model.beginAdd() }
                    .disabled(model.isBusy || model.pendingNewLogin)
            }
        }
    }

    private func row(_ profile: Profile) -> some View {
        let active = profile.id == model.live?.matchingProfileID
        let favorite = model.settings.favoriteProfileIDs.contains(profile.id)
        return HStack(spacing: 10) {
            Initials(text: profile.identity?.initials ?? String(profile.displayName.prefix(1)).uppercased(),
                     tint: ProviderStyle.codex.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName(for: profile))
                        .fontWeight(active ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if active {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ProviderStyle.codex.accent)
                    }
                }
                Text(detail(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.toggleFavorite(profile)
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .foregroundStyle(favorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(favorite ? "Remove from favorites" : "Add to favorites")
            if !active {
                Button("Switch") { model.switchTo(profile) }
                    .disabled(!model.canSwitch)
            }
            Menu {
                Button("Rename…") { model.beginRename(profile) }
                Button("Remove…", role: .destructive) { confirmingRemoval = profile }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isBusy || model.pendingNewLogin)
        }
    }

    private func detail(_ profile: Profile) -> String {
        var parts: [String] = []
        if let subtitle = profile.identity?.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if let usage = model.profileUsage[profile.id]?.usage {
            parts.append(usage.windows.map { "\($0.label) \($0.remainingDisplay)%" }.joined(separator: " · "))
        } else if model.profileUsage[profile.id]?.error != nil {
            parts.append("Usage unavailable")
        }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in
                model.settings[keyPath: keyPath] = value
                model.updateSettings()
            })
    }
}
