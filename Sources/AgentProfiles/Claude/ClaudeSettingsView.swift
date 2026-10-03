import SwiftUI
import AgentUI
import ClaudeProfilesCore

/// Settings → Claude: profiles and what Claude Profiles' panel and window
/// used to offer (Desktop and CLI switching, rename, delete, order, shared
/// session history, CLI setup).
struct ClaudeSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            if !state.claudeAppFound {
                Section {
                    Label("Claude.app not found in /Applications or ~/Applications.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if state.brokenLink {
                Section {
                    Label("The Claude folder link is broken. Switching to any profile repairs it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            if state.mode == .needsSetup {
                setup
            }
            if state.mode == .ready || !state.allProfiles.isEmpty {
                profiles
            }
            if !state.profiles.isEmpty {
                history
            }
            cli
        }
        .formStyle(.grouped)
        .disabled(state.isSwitching)
        .onAppear { state.refresh() }
    }

    private var setup: some View {
        Section("Get Started") {
            Text("Setting up creates your first Desktop profile and saves your current Claude login, if any. Claude restarts once.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Set Up Profiles…") { state.setUpProfiles() }
                    .disabled(!state.claudeAppFound)
            }
        }
    }

    private var profiles: some View {
        Section {
            if state.allProfiles.isEmpty {
                Text("No saved Claude profiles.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(state.allProfiles.enumerated()), id: \.element) { index, name in
                row(name, index: index)
            }
        } header: {
            Text("Profiles")
        } footer: {
            HStack {
                Text("Switching the Desktop profile restarts Claude. ⌘⌥1…9 switches from anywhere.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { state.revealProfilesFolder() }
                Button("New Profile…") { state.newProfile() }
            }
        }
    }

    private func row(_ name: String, index: Int) -> some View {
        let desktop = name == state.activeProfile
        let cli = state.cliSetUp && name == state.activeCLIProfile
        return HStack(spacing: 10) {
            Initials(text: String(name.prefix(2)).uppercased(), tint: ProviderStyle.claude.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .fontWeight(desktop ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if desktop { tag("Desktop") }
                    if cli { tag("CLI") }
                }
                Text(usageLine(name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !desktop {
                Button("Switch") { state.switchTo(name) }
                    .disabled(!state.canSwitchDesktop)
                    .help("Use this profile in Claude Desktop (Claude restarts)")
            }
            Menu {
                if state.cliSetUp, !cli {
                    Button("Use for Claude Code (CLI)") { state.switchCLI(name) }
                }
                Button("Rename…") { state.renameProfile(name) }
                Divider()
                Button("Move Up") { move(index, by: -1) }
                    .disabled(index == 0)
                Button("Move Down") { move(index, by: 1) }
                    .disabled(index == state.allProfiles.count - 1)
                Divider()
                Button("Delete…", role: .destructive) { state.deleteProfile(name) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var history: some View {
        Section {
            Toggle("Share session history across profiles", isOn: Binding(
                get: { state.sharedHistoryEnabled },
                set: { $0 ? state.enableSharedHistory() : state.disableSharedHistory() }))
            HStack {
                Text("Undo sharing per account from the backup made when it was turned on.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore from Backup…") { state.restoreSharedHistory() }
            }
        } header: {
            Text("Session History")
        } footer: {
            Text("Every profile sees one combined sidebar. A timestamped backup is saved in your home folder first.")
                .foregroundStyle(.secondary)
        }
    }

    private var cli: some View {
        Section {
            if state.cliSetUp {
                Picker("Claude Code uses", selection: Binding(
                    get: { state.activeCLIProfile ?? "" },
                    set: { state.switchCLI($0.isEmpty ? nil : $0) })) {
                    Text("Default (~/.claude)").tag("")
                    ForEach(state.allProfiles, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Show Default in the menu", isOn: Binding(
                    get: { !state.cliDefaultHidden },
                    set: { state.setDefaultRowHidden(!$0) }))
                HStack {
                    Spacer()
                    Button("Terminal Setup…") { state.showCLIPathHelp() }
                }
            } else {
                Text("Use the same profiles for `claude` in the terminal. Each profile logs in once there too.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Set Up CLI Profiles…") { state.setUpCLIProfiles() }
                }
            }
        } header: {
            Text("Claude Code (CLI)")
        } footer: {
            if state.cliSetUp {
                Text("Applies to `claude` commands started from now on; running sessions keep their account.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ProviderStyle.claude.accent)
    }

    private func usageLine(_ name: String) -> String {
        guard let usage = state.usage[name] else {
            return state.profiles.contains(name) ? "No usage data yet" : "Not used in Claude Desktop yet"
        }
        var parts: [String] = []
        if let five = usage.fiveHour { parts.append("Session \(five.remainingPercent)%") }
        if let week = usage.sevenDay { parts.append("Weekly \(week.remainingPercent)%") }
        parts.append(UsageFormat.updatedText(usage.asOf).lowercased())
        return parts.joined(separator: " · ")
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard state.allProfiles.indices.contains(target) else { return }
        state.allProfiles.swapAt(index, target)
        state.saveProfileOrder()
    }
}
