import SwiftUI
import ServiceManagement
import AgentUI
import CodexProfilesUI
import ProvidersCore
import UsageHistoryCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notifications, claude, codex, providers, history, about

    static let storageKey = "settingsPane"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .claude: "Claude"
        case .codex: "Codex"
        case .providers: "More Providers"
        case .history: "History"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .notifications: "bell.badge.fill"
        case .providers: "square.grid.2x2.fill"
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
        case .notifications: .red
        case .providers: .purple
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
    let providers: ExtraProvidersModel
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
                case .notifications: NotificationSettingsView()
                case .providers: ProvidersSettingsView(providers: providers)
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
    @AppStorage(Preferences.menuBarMetricKey) private var metric: MenuBarMetric = .session
    @AppStorage(Preferences.panelHotKeyKey) private var panelHotKey = true
    @AppStorage(Preferences.followTightestKey) private var followTightest = false
    @AppStorage(UsageDisplay.showsUsedKey) private var showsUsed = false
    @AppStorage(UsageDisplay.resetClockKey) private var resetAsClock = false
    @AppStorage(UsageDisplay.hidePersonalKey) private var hidePersonal = false
    @AppStorage(UsageDisplay.sortByHeadroomKey) private var sortByHeadroom = true
    @AppStorage(StatusModel.enabledKey) private var statusChecks = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Show usage for", selection: $provider) {
                    ForEach(MenuBarProvider.allCases) { Text($0.style.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Follow the active app", isOn: $followActiveApp)
                Toggle("Follow whichever has less left", isOn: $followTightest)
                Toggle("Show percentage next to the icon", isOn: $showPercent)
                Picker("Percentage shows", selection: $metric) {
                    ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!showPercent)
                Toggle("Open the panel with ⌘⌥0", isOn: $panelHotKey)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("The icon's top bar is the session window, the bottom bar the weekly one. When following the active app, bringing Claude or Codex to the front switches the icon to it; other apps, including terminals, keep the last one. Otherwise “less left” shows the provider closer to its limit.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show estimated cost", isOn: $showCost)
                Toggle("Show used instead of left", isOn: $showsUsed)
                Toggle("Show resets as clock times", isOn: $resetAsClock)
                Toggle("Sort accounts by what they have left", isOn: $sortByHeadroom)
                Toggle("Hide email addresses", isOn: $hidePersonal)
                Toggle("Show provider status incidents", isOn: $statusChecks)
            } header: {
                Text("Panel")
            } footer: {
                Text("Clicking a percentage or a reset time in the panel flips it too. Hiding email addresses helps when sharing your screen. Status incidents come from each provider's public status page.")
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
            Text("Switch Claude and Codex accounts and keep an eye on every AI tool's usage limits.")
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
                .padding(.top, 6)
            Spacer().frame(height: 10)
            Text("Inspired by OpenUsage by Robin Ebers and CodexBar by Peter Steinberger.")
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


struct NotificationSettingsView: View {
    @AppStorage(UsageAlertSettings.thresholdsKey) private var thresholds = true
    @AppStorage(UsageAlertSettings.warningKey) private var warningLeft = 25.0
    @AppStorage(UsageAlertSettings.criticalKey) private var criticalLeft = 10.0
    @AppStorage(UsageAlertSettings.willRunOutKey) private var willRunOut = true
    @AppStorage(UsageAlertSettings.resetsKey) private var resets = true
    @AppStorage(UsageAlertSettings.useItOrLoseItKey) private var useItOrLoseIt = false

    var body: some View {
        Form {
            Section {
                Toggle("Low usage", isOn: $thresholds)
                LabeledContent("Warn at") {
                    HStack {
                        Slider(value: $warningLeft, in: 15...60, step: 5)
                            .frame(width: 180)
                        Text("\(Int(warningLeft))% left").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(!thresholds)
                LabeledContent("Critical at") {
                    HStack {
                        Slider(value: $criticalLeft, in: 5...25, step: 5)
                            .frame(width: 180)
                        Text("\(Int(criticalLeft))% left").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(!thresholds)
            } header: {
                Text("Limits")
            } footer: {
                Text("Each limit notifies once per window, at the deepest level it has reached. A critical Claude or Codex alert suggests the account with the most left; clicking the notification switches to it.")
                    .foregroundStyle(.secondary)
            }
            .onChange(of: warningLeft) { _, value in if criticalLeft >= value { criticalLeft = max(5, value - 5) } }
            .onChange(of: criticalLeft) { _, value in if warningLeft <= value { warningLeft = min(60, value + 5) } }
            Section {
                Toggle("Will run out before it resets", isOn: $willRunOut)
                Toggle("A used-up limit has reset", isOn: $resets)
                Toggle("Weekly limit resets soon with most of it unused", isOn: $useItOrLoseIt)
            } header: {
                Text("Pace")
            } footer: {
                Text("“Will run out” uses the burn rate so far in the window. The weekly reminder fires a day before the reset when more than half is left.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Turns extra providers on or off. Each one reads the sign-in its own app
/// or CLI keeps on this Mac and asks that service for usage.
struct ProvidersSettingsView: View {
    @ObservedObject var providers: ExtraProvidersModel

    var body: some View {
        Form {
            Section {
                ForEach(providers.providers, id: \.id) { provider in
                    row(provider)
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Turned on, a provider reads the sign-in its own app or CLI left on this Mac and asks that service for your usage every five minutes. Agent Profiles never changes those files. Sign in or out in the provider's own tool.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ provider: any UsageProvider) -> some View {
        let style = ExtraProvidersModel.style(provider)
        let signedIn = providers.isSignedIn(provider)
        let state = providers.states[provider.id]
        return HStack(spacing: 10) {
            ProviderLogo(style, size: 14)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(style.accent.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Group {
                    if !signedIn {
                        Text("Not signed in on this Mac")
                    } else if let error = state?.error, providers.isEnabled(provider.id) {
                        Text(error).foregroundStyle(.orange)
                    } else if let snapshot = state?.snapshot, providers.isEnabled(provider.id) {
                        Text([snapshot.account, snapshot.plan, UsageFormat.updatedText(snapshot.fetchedAt)]
                            .compactMap { $0 }.joined(separator: " · "))
                    } else {
                        Text("Signed in")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { providers.isEnabled(provider.id) },
                                     set: { providers.setEnabled(provider.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}
