import SwiftUI
import AppKit
import ServiceManagement
import ClaudeProfilesCore

let accent = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude Profiles' orange

// MARK: - Panel

/// The popover: header (active profile + usage summary + refresh), pill tabs,
/// scrolling content, pinned footer — fixed size so long profile lists scroll
/// instead of growing past the screen.
struct PanelView: View {
    @ObservedObject var state: AppState
    @State private var tab: PanelTab = .profiles
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var filter = ""

    static let width: CGFloat = 340
    static let height: CGFloat = 480

    enum PanelTab: String, CaseIterable, Identifiable {
        case profiles = "Profiles"
        case usage = "Usage"
        case more = "More"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            if state.mode == .needsSetup {
                if !state.claudeAppFound {
                    Banner(icon: "exclamationmark.triangle.fill",
                           text: "Claude.app not found in /Applications or ~/Applications")
                        .padding(12)
                }
                Spacer()
                SetupView(state: state)
                Spacer()
            } else {
                tabBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .profiles: profilesTab
                        case .usage: UsageTab(state: state)
                        case .more: moreTab
                        }
                    }
                    .padding(12)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
            }
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: Self.width, height: Self.height)
        .onAppear { state.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if state.mode == .ready, let active = state.activeProfile {
                Avatar(name: active, active: true, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(active)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude").font(.headline)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            IconButton(systemName: "macwindow.on.rectangle", help: "Open as window") {
                state.openWindowHandler?()
            }
            IconButton(systemName: state.usageScanRunning ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                       help: "Re-read usage from Claude's cache") {
                state.refreshUsage()
            }
            .disabled(state.usageScanRunning)
        }
    }

    private var subtitle: String {
        if state.isSwitching { return "Switching…" }
        guard state.mode == .ready else { return "One folder per account" }
        guard let active = state.activeProfile else { return "No active profile" }
        guard let usage = state.usage[active], usage.hasLiveWindows else { return "No usage data yet" }
        return usage.levels.map { "\($0.label) \($0.remaining)% left" }.joined(separator: " · ")
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases) { candidate in
                Button {
                    tab = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(tab == candidate ? accent.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(tab == candidate ? accent : Color.secondary)
                }
                .buttonStyle(PressableStyle())
            }
            Spacer()
        }
    }

    // MARK: Profiles tab

    // Rename/delete/hide live in the window app only — hover buttons made
    // these compact rows a mess. The panel is for switching.
    private var profilesTab: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !state.claudeAppFound {
                Banner(icon: "exclamationmark.triangle.fill",
                       text: "Claude.app not found in /Applications or ~/Applications")
            }
            if state.brokenLink {
                Banner(icon: "link.badge.plus",
                       text: "Active profile is missing — pick a profile to fix it")
            }
            if state.allProfiles.count > 8 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("Filter profiles", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                .padding(.bottom, 2)
            }
            if state.cliSetUp && !state.cliDefaultHidden,
               filter.isEmpty || "default".localizedCaseInsensitiveContains(filter) {
                // The CLI's default account: plain ~/.claude, no Desktop side.
                ProfileRow(name: "Default",
                           hasDesktop: false, hasCLI: true,
                           desktopActive: false,
                           cliActive: state.activeCLIProfile == nil,
                           disabled: false,
                           onDesktop: nil,
                           onCLI: { state.switchCLI(nil) })
            }
            ForEach(filteredProfiles, id: \.self) { name in
                ProfileRow(
                    name: name,
                    usage: state.usage[name],
                    hasDesktop: state.profiles.contains(name),
                    hasCLI: state.cliCreated.contains(name),
                    desktopActive: name == state.activeProfile,
                    cliActive: name == state.activeCLIProfile,
                    disabled: !state.claudeAppFound || state.isSwitching,
                    onDesktop: { state.switchTo(name) },
                    onCLI: state.cliSetUp ? { state.switchCLI(name) } : nil
                )
            }
            ActionRow(icon: "plus.circle.fill", title: "New Profile", tint: accent,
                      disabled: !state.claudeAppFound || state.isSwitching) {
                state.newProfile()
            }
        }
    }

    private var filteredProfiles: [String] {
        filter.isEmpty ? state.allProfiles
            : state.allProfiles.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    // MARK: More tab

    private var moreTab: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !state.cliSetUp {
                ActionRow(icon: "terminal", title: "Set Up CLI Profiles…") {
                    state.setUpCLIProfiles()
                }
            } else {
                ActionRow(icon: "questionmark.circle", title: "CLI Terminal Setup…") {
                    state.showCLIPathHelp()
                }
            }
            if !state.sharedHistoryEnabled {
                ActionRow(icon: "clock.arrow.2.circlepath", title: "Share Session History…",
                          disabled: !state.claudeAppFound || state.isSwitching) {
                    state.enableSharedHistory()
                }
            }
            ActionRow(icon: "folder", title: "Reveal Profiles in Finder") {
                state.revealProfilesFolder()
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("[Agent Profiles] Launch at login failed: %@", error.localizedDescription)
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            if let scanned = state.lastUsageScan {
                Text(scanned.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Last usage scan")
            }
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Usage tab

/// The active profile's cached limits as a hero readout, then every profile's
/// meters — same battery-style remaining semantics as the window app.
private struct UsageTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            activeSection
            Divider()
            allSection
        }
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Active profile")
            if let active = state.activeProfile {
                if let usage = state.usage[active], usage.hasLiveWindows {
                    let remaining = usage.fiveHourRemaining ?? 100
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(remaining)%")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(ProfileUsage.remainingColor(remaining))
                        Text("of the 5-hour window left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack(spacing: 16) {
                        if let five = usage.fiveHour {
                            PanelStat(label: "5h resets", value: Self.resetText(five))
                        }
                        if let week = usage.sevenDay {
                            PanelStat(label: "Week left", value: "\(week.remainingPercent)%",
                                      color: ProfileUsage.remainingColor(week.remainingPercent))
                            PanelStat(label: "Week resets", value: Self.resetText(week))
                        }
                    }
                    .padding(.top, 2)
                    Text("From Claude's last check, \(Self.relative(usage.asOf))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                } else {
                    Text("No usage data yet — open Claude with this profile once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No active profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var allSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("All profiles")
            ForEach(state.allProfiles, id: \.self) { name in
                HStack(spacing: 8) {
                    Avatar(name: name, active: name == state.activeProfile, size: 16)
                    Text(name)
                        .font(.system(size: 12,
                                      weight: name == state.activeProfile ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let usage = state.usage[name], usage.hasLiveWindows {
                        UsageLevels(usage: usage, barWidth: 30)
                    } else {
                        Text("no data")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(name == state.activeProfile ? accent.opacity(0.10)
                              : Color.primary.opacity(0.045))
                )
            }
        }
    }

    /// "14:30" today, "Tue 09:00" otherwise; an expired window already reset.
    static func resetText(_ window: ProfileUsage.Window) -> String {
        guard !window.expired, let date = window.resetsAt else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

/// Small label-over-value column, ClaudeBar-style.
struct PanelStat: View {
    let label: String
    let value: String
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color ?? .primary)
        }
    }
}

// MARK: - Rows

/// One row per profile, tagged per context: the window icon is Claude Desktop,
/// the terminal icon is claude CLI. At rest a row shows only its *active* tags
/// (accent); hovering reveals both switch buttons — same pattern as the
/// rename/delete actions, so the list stays quiet.
struct ProfileRow: View {
    let name: String
    var usage: ProfileUsage? = nil
    let hasDesktop: Bool
    let hasCLI: Bool
    let desktopActive: Bool
    let cliActive: Bool
    let disabled: Bool
    let onDesktop: (() -> Void)?
    let onCLI: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Row click keeps the old meaning: switch Desktop (or CLI for
            // rows that have no Desktop side, like Default).
            Button(action: { (onDesktop ?? onCLI)?() }) {
                HStack(spacing: 8) {
                    // Desktop is the row's primary identity — CLI-active alone
                    // shows only the accent terminal tag, keeping hierarchy clear.
                    Avatar(name: name, active: desktopActive)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                        if let usage, usage.hasLiveWindows {
                            UsageLevels(usage: usage, barWidth: 22)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(onDesktop != nil ? (disabled || desktopActive) : cliActive)

            if let onDesktop, desktopActive || (hovering && !disabled) {
                ContextIcon(systemName: "macwindow",
                            active: desktopActive, present: hasDesktop, disabled: disabled,
                            help: desktopActive ? "Active in Claude Desktop"
                                : hasDesktop ? "Use in Claude Desktop"
                                : "Use in Claude Desktop (logs in once)",
                            action: onDesktop)
            }
            if let onCLI, cliActive || hovering {
                ContextIcon(systemName: "terminal",
                            active: cliActive, present: hasCLI, disabled: false,
                            help: cliActive ? "Active for claude in the terminal"
                                : hasCLI ? "Use for claude in the terminal — instant"
                                : "Use for claude in the terminal (logs in once)",
                            action: onCLI)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(desktopActive ? accent.opacity(0.13)
                      : hovering ? Color.primary.opacity(0.08)
                      : Color.primary.opacity(0.045))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The per-context tag + switch button on a profile row.
struct ContextIcon: View {
    let systemName: String
    let active: Bool
    let present: Bool
    let disabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(accent)
                    : hovering ? AnyShapeStyle(Color.primary)
                    : AnyShapeStyle(Color.secondary.opacity(present ? 0.9 : 0.5)))
                .frame(width: 20, height: 20)
                .background(Circle().fill(active ? accent.opacity(0.15)
                    : hovering ? Color.primary.opacity(0.1)
                    : .clear))
        }
        .buttonStyle(PressableStyle())
        .disabled(active || disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

struct ActionRow: View {
    let icon: String
    let title: String
    var tint: Color = .primary
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint == .primary ? Color.secondary : tint)
                    .frame(width: 18)
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering && !disabled ? Color.primary.opacity(0.06) : .clear)
            )
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Pieces

struct Avatar: View {
    let name: String
    let active: Bool
    var size: CGFloat = 18

    /// Letters first: "008-purenomo" → "PU", not the "00" every numbered
    /// profile shares. Digits only when the name has no letters at all.
    static func initials(_ name: String) -> String {
        let letters = name.filter(\.isLetter)
        let source = letters.isEmpty ? name.filter(\.isNumber) : letters
        return String((source.isEmpty ? name : source).prefix(2)).uppercased()
    }

    private var hue: Double {
        Double(name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360
    }

    var body: some View {
        ZStack {
            Circle().fill(
                active
                ? AnyShapeStyle(LinearGradient(colors: [accent, accent.opacity(0.7)],
                                               startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(Color(hue: hue, saturation: 0.35, brightness: 0.75).opacity(0.85))
            )
            Text(Self.initials(name))
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

struct Banner: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.orange)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.1)))
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(accent)
            Text("One directory per account,\nswitch without ever logging in again.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Set Up Profiles…") { state.setUpProfiles() }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(!state.claudeAppFound || state.isSwitching)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

/// Press feedback: subtle scale, fast ease-out. Never from scale(0), never slow.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
