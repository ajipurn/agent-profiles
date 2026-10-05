import SwiftUI
import ServiceManagement
import AgentUI
import CodexProfilesUI
import UsageHistoryCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, claude, codex, history, about

    static let storageKey = "settingsPane"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .claude: "Claude"
        case .codex: "Codex"
        case .history: "History"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .claude: ProviderStyle.claude.symbol
        case .codex: ProviderStyle.codex.symbol
        case .history: "chart.xyaxis.line"
        case .about: "info.circle.fill"
        }
    }

    /// Provider panes show the brand mark instead of a symbol.
    var logo: ProviderStyle? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        default: nil
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .claude: ProviderStyle.claude.accent
        case .codex: ProviderStyle.codex.accent
        case .history: .indigo
        case .about: .blue
        }
    }
}

/// The Settings window: a sidebar of panes, as in System Settings.
struct SettingsView: View {
    let claude: AppState
    let codex: AppModel
    let updates: UpdateController
    let history: UsageHistory
    @AppStorage(SettingsPane.storageKey) private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding<SettingsPane?>(
                get: { pane }, set: { if let new = $0 { pane = new } })) { item in
                Label {
                    Text(item.title)
                } icon: {
                    Group {
                        if let logo = item.logo {
                            ProviderLogo(logo, size: 13)
                        } else {
                            Image(systemName: item.symbol)
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(item.tint.gradient))
                }
                .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralSettingsView(updates: updates)
                case .claude: ClaudeSettingsView(state: claude)
                case .codex: CodexSettingsView(model: codex)
                case .history: HistoryView(history: history, accounts: historyAccounts)
                case .about: AboutView(updates: updates)
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    /// Accounts in the order the menus list them: Claude profiles as arranged
    /// in Settings, Codex accounts in hotkey order.
    private func historyAccounts(_ provider: UsageSample.Provider) -> [HistoryAccount] {
        switch provider {
        case .claude:
            claude.manager.ordered(claude.profiles).map { HistoryAccount(id: $0, name: $0) }
        case .codex:
            codex.hotkeyAccountIDs.map { HistoryAccount(id: $0, name: codex.accountName($0) ?? "Codex account") }
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var updates: UpdateController
    @AppStorage(Preferences.menuBarProviderKey) private var provider: MenuBarProvider = .claude
    @AppStorage(Preferences.showPercentKey) private var showPercent = true
    @AppStorage(Preferences.followActiveAppKey) private var followActiveApp = true
    @AppStorage(Preferences.showCostKey) private var showCost = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Show usage for", selection: $provider) {
                    ForEach(MenuBarProvider.allCases) { Text($0.style.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Follow the active app", isOn: $followActiveApp)
                Toggle("Show percentage next to the icon", isOn: $showPercent)
                Toggle("Show estimated cost in the menu", isOn: $showCost)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("The icon's top bar is the session window, the bottom bar the weekly one. The menu shows both providers. When following the active app, bringing Claude or Codex to the front switches the icon to it; other apps, including terminals, keep the last one.")
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("[Agent Profiles] Launch at login failed: %@", error.localizedDescription)
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecks }, set: { updates.setAutomaticChecks($0) }))
                    .disabled(!updates.isAvailable)
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { updates.automaticallyInstalls }, set: { updates.setAutomaticInstallation($0) }))
                    .disabled(!updates.isAvailable || !updates.automaticallyChecks)
                HStack {
                    if let reason = updates.unavailableReason {
                        Text(reason).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            } header: {
                Text("Updates")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Quit Agent Profiles") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    @ObservedObject var updates: UpdateController

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Agent Profiles")
                .font(.title2.weight(.semibold))
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("Switch Claude and Codex accounts and keep an eye on their usage limits.")
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
                .padding(.top, 6)
            Spacer().frame(height: 10)
            Text("Menu design inspired by CodexBar by Peter Steinberger.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Not affiliated with Anthropic or OpenAI.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
