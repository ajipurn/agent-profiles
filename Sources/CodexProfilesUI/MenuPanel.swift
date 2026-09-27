import SwiftUI
import CodexProfilesCore

struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nameFieldFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var profileConfirmingDelete: Profile?
    @State private var measuredContentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                panelContent
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { measuredContentHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in
                                    measuredContentHeight = height
                                }
                        }
                    )
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: panelHeight)

            footer
        }
        .frame(width: PanelDS.panelWidth)
        .background(.regularMaterial)
        .onAppear {
            model.refresh()
            model.startLiveUsagePolling()
        }
        .onDisappear {
            model.stopLiveUsagePolling()
        }
        .background {
            Button("Find account") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .onChange(of: model.editor) { _, editor in
            nameFieldFocused = editor != nil
        }
        .onChange(of: model.visibleProfiles.map(\.id)) { _, ids in
            if let target = profileConfirmingDelete, !ids.contains(target.id) {
                profileConfirmingDelete = nil
            }
        }
    }

    /// The plan already appears as a pill next to the usage card, so the subtitle
    /// shows the workspace instead of repeating it.
    private var heroSubtitle: String {
        guard let identity = model.live?.identity else { return model.currentSubtitle }
        if let org = identity.organizations.first, !org.isEmpty { return org }
        if let plan = identity.plan, !plan.isEmpty { return AccountIdentity.displayPlan(plan) }
        return model.currentSubtitle
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleBar
            header
            feedback
            if model.editor != nil {
                nameEditor
            }
            accountsSection
        }
        .padding(PanelDS.contentPadding)
    }

    /// Follows the real content height so short lists leave no dead gap, and clamps at a
    /// maximum so long lists scroll instead of growing the menu bar window forever.
    private var panelHeight: CGFloat {
        let measured = measuredContentHeight > 0 ? measuredContentHeight : estimatedContentHeight
        return min(PanelDS.maxPanelHeight, max(140, measured))
    }

    /// First-paint fallback used until the content has been measured.
    private var estimatedContentHeight: CGFloat {
        let quotaHeight: CGFloat = model.live?.file?.isChatGPTSession == true ? 208 : 30
        let rowH: CGFloat = model.settings.hideEmails ? 72 : 80
        let rowCount = CGFloat(max(0, model.visibleProfiles.count))
        let rowsHeight: CGFloat
        if model.profiles.isEmpty || model.visibleProfiles.isEmpty {
            rowsHeight = 190
        } else {
            rowsHeight = 56 + rowCount * rowH
        }
        let editorHeight: CGFloat = model.editor == nil ? 0 : 196
        let hasErrorBanner = model.error != nil && model.editor == nil
        let hasStatusBanner = model.status != nil && (model.isBusy || model.awaitingLogin)
        let feedbackHeight: CGFloat = (hasErrorBanner || hasStatusBanner) ? 60 : 0
        let total: CGFloat = 188 + quotaHeight + rowsHeight + editorHeight + feedbackHeight
        return min(PanelDS.maxPanelHeight, total)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle.stack.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(AvatarPalette.gradient(for: "Codex Profiles"))
                    )
                Text("Codex Profiles")
                    .font(PanelDS.title)
                Spacer()
            }
            Button {
                model.settings.hideEmails.toggle()
                model.updateSettings()
            } label: {
                Image(systemName: model.settings.hideEmails ? "eye.slash" : "eye")
            }
            .buttonStyle(PanelIconButtonStyle(size: 28, active: model.settings.hideEmails))
            .help(model.settings.hideEmails ? "Show email addresses" : "Hide email addresses")
            .accessibilityLabel(model.settings.hideEmails ? "Show email addresses" : "Hide email addresses")
            .disabled(model.isBusy || model.pendingNewLogin)
        }
        .foregroundStyle(.secondary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("CURRENT ACCOUNT")
                    .font(PanelDS.microLabel)
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                statusPill
            }
            HStack(alignment: .center, spacing: 12) {
                AccountAvatar(seed: model.currentTitle, initials: model.live?.identity?.initials ?? "–", size: 42, emphasized: true)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.currentTitle)
                        .font(PanelDS.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.currentTitle)
                    Text(heroSubtitle)
                        .font(PanelDS.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(heroSubtitle)
                }
            }
            if model.live?.file?.isChatGPTSession == true {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    UsageCard(state: model.liveUsage, now: context.date) {
                        model.refreshUsage(force: true)
                    }
                }
            } else if model.live?.identity?.authMode == "apikey" {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                    Text("API key usage is billed separately.")
                        .font(PanelDS.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045))
                )
            }
        }
        .padding(14)
        .panelCard()
    }
    @ViewBuilder
    private var statusPill: some View {
        if model.live?.matchingProfileID != nil {
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.green.opacity(0.12)))
                .overlay(Capsule().stroke(Color.green.opacity(0.22), lineWidth: 1))
        } else if model.needsSave {
            Text("Unsaved")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.orange.opacity(0.13)))
                .overlay(Capsule().stroke(Color.orange.opacity(0.25), lineWidth: 1))
        }
    }
    @ViewBuilder
    private var feedback: some View {
        if let error = model.error, model.editor == nil {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    model.dismissError()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
            .accessibilityElement(children: .contain)
        } else if let status = model.status, model.isBusy || model.awaitingLogin {
            HStack(spacing: 9) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.awaitingLogin {
                    Button("Cancel login") {
                        model.cancelLogin()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .accessibilityElement(children: .contain)
        }
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(editorTitle)
                    .font(.subheadline.weight(.semibold))
                Text(editorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Account name")
                    .font(.caption.weight(.medium))
                TextField("For example, Work", text: Bindable(model).draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFieldFocused)
                    .onSubmit { model.commitEditor() }

                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Error: \(error)")
                }
            }

            HStack(spacing: 8) {
                Button("Cancel") { model.cancelEditor() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy)
                Spacer()
                Button {
                    model.commitEditor()
                } label: {
                    HStack(spacing: 6) {
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(editorConfirmTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || model.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }

    private var editorTitle: String {
        switch model.editor {
        case .save: "Save this account"
        case .rename: "Rename account"
        case .add: "Finish adding account"
        case .none: ""
        }
    }

    private var editorDescription: String {
        switch model.editor {
        case .save:
            "Choose a name that makes this login easy to recognize."
        case .rename:
            "Choose how this account appears in the list."
        case .add:
            "Signed in as \(model.currentTitle). Choose how it appears in the list."
        case .none:
            ""
        }
    }

    private var editorConfirmTitle: String {
        switch model.editor {
        case .rename: "Save name"
        default: "Save account"
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Accounts")
                    .font(PanelDS.title)
                if !model.profiles.isEmpty {
                    Text("\(model.profiles.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
                Button {
                    model.beginAdd()
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isBusy || model.pendingNewLogin)
            }

            if !model.profiles.isEmpty {
                accountFilters
            }

            if model.needsSave, model.editor == nil {
                HStack(spacing: 9) {
                    Image(systemName: "bookmark")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("This login isn’t saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save account") { model.beginSave() }
                        .disabled(model.isBusy || model.pendingNewLogin)
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.medium))
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.09))
                )
            }

            if let target = profileConfirmingDelete, model.editor == nil {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remove \(model.displayName(for: target))?")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.displayName(for: target))
                        Text(target.id == model.live?.matchingProfileID ? "This removes the saved profile. You’ll remain signed in to the account." : "You won’t be able to switch back without signing in again.")
                            .font(PanelDS.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Cancel") { profileConfirmingDelete = nil }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Remove account") {
                                let confirmed = target
                                profileConfirmingDelete = nil
                                model.delete(confirmed)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.red)
                            .disabled(model.isBusy || model.pendingNewLogin)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.red.opacity(0.22), lineWidth: 1)
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Confirm removing \(model.displayName(for: target))")
            }

            if model.profiles.isEmpty {
                emptyState
            } else if model.visibleProfiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.favoritesOnly ? "star" : "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(model.favoritesOnly && model.searchText.isEmpty ? "No favorite accounts yet" : "No matching accounts")
                        .font(.subheadline.weight(.medium))
                    Text(model.favoritesOnly ? "Star an account from its action menu, or show all accounts." : "Try another name, email, or workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Show all accounts") {
                        model.searchText = ""
                        model.favoritesOnly = false
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            } else {
                profileRows
            }
        }
    }

    private var accountFilters: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12, weight: .medium))
                TextField("Search accounts", text: Bindable(model).searchText)
                    .textFieldStyle(.plain)
                    .font(PanelDS.body)
                    .focused($searchFocused)
                    .accessibilityLabel("Search by account name, email, or workspace")
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: PanelDS.controlRadius, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: PanelDS.controlRadius, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            Button { model.favoritesOnly.toggle() } label: {
                Image(systemName: model.favoritesOnly ? "star.fill" : "star")
            }
            .buttonStyle(PanelIconButtonStyle(size: 32, active: model.favoritesOnly, tint: .orange))
            .help("Show favorites only")
            .accessibilityLabel("Show favorites only")

            Menu {
                Picker("Sort accounts", selection: setting(\.sortOrder)) {
                    ForEach(ProfileSortOrder.allCases, id: \.self) { order in
                        Text(order.title).tag(order)
                    }
                }
                Divider()
                Text("Active account and favorites stay on top")
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Sort: \(model.settings.sortOrder.title)")
            .accessibilityLabel("Sort accounts")
        }
        .font(.caption)
    }

    private var profileRows: some View {
        LazyVStack(spacing: 8) {
            ForEach(model.visibleProfiles) { profile in
                profileRow(profile)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: model.needsSave ? "bookmark" : "person.crop.circle.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 3) {
                Text(model.needsSave ? "Save your first account" : "No saved accounts")
                    .font(.subheadline.weight(.medium))
                Text(model.needsSave
                     ? "Save this login so you can switch back to it later."
                     : "Add an account to switch logins without signing in each time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(model.needsSave ? "Save this account" : "Add your first account") {
                if model.needsSave {
                    model.beginSave()
                } else {
                    model.beginAdd()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isBusy || model.pendingNewLogin)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func profileRow(_ profile: Profile) -> some View {
        let isActive = profile.id == model.live?.matchingProfileID
        let usageState = model.profileUsage[profile.id]

        return HStack(spacing: 6) {
            Button {
                model.switchTo(profile)
            } label: {
                HStack(spacing: 11) {
                    ZStack(alignment: .bottomTrailing) {
                        AccountAvatar(seed: profile.identity?.email ?? profile.name, initials: profile.identity?.initials ?? "C", size: 34, emphasized: isActive)
                        if isActive {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(Color.accentColor))
                                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                                .offset(x: 2, y: 2)
                                .accessibilityHidden(true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(model.displayName(for: profile))
                                .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(model.displayName(for: profile))
                            if model.settings.favoriteProfileIDs.contains(profile.id) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                            }
                        }
                        if !model.settings.hideEmails, let email = profile.identity?.email,
                           email != profile.displayName {
                            Text(email)
                                .font(PanelDS.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(email)
                        }
                        if let subtitle = profile.identity?.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(PanelDS.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(subtitle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    UsageCompactLabel(state: usageState)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(profileAccessibilityLabel(profile, active: isActive))
            .accessibilityHint(isActive ? "Current account" : "Switch to this account")

            Menu {
                Button(model.settings.favoriteProfileIDs.contains(profile.id) ? "Remove from favorites" : "Add to favorites",
                       systemImage: model.settings.favoriteProfileIDs.contains(profile.id) ? "star.slash" : "star") {
                    model.toggleFavorite(profile)
                }
                Divider()
                if usageState?.error != nil {
                    Button("Sign in again…") { model.beginAdd() }
                    Divider()
                }
                Button("Rename…") { model.beginRename(profile) }
                Button("Remove saved account…", role: .destructive) {
                    profileConfirmingDelete = profile
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Actions for \(model.displayName(for: profile))")
            .help("Account actions")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: PanelDS.rowRadius, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.032))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PanelDS.rowRadius, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: isActive ? Color.accentColor.opacity(0.10) : .clear, radius: 6, y: 1)
        .contextMenu {
            Button(model.settings.favoriteProfileIDs.contains(profile.id) ? "Remove from favorites" : "Add to favorites") {
                model.toggleFavorite(profile)
            }
            Button("Rename…") { model.beginRename(profile) }
            Button("Remove saved account…", role: .destructive) {
                profileConfirmingDelete = profile
            }
        }
        .disabled(model.isBusy || model.pendingNewLogin)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.refresh()
                model.refreshUsage(force: true)
            } label: {
                HStack(spacing: 6) {
                    if model.isRefreshingUsage {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(model.isRefreshingUsage ? "Refreshing…" : "Refresh")
                }
                .frame(minHeight: 28)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Refresh account usage")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isBusy || model.pendingNewLogin || model.isRefreshingUsage)

            if let checked = model.lastUsageCheck {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(lastCheckText(checked, now: context.date))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Last checked \(checked.formatted(date: .abbreviated, time: .standard))")
                        .accessibilityLabel("Last usage check \(checked.formatted())")
                }
            }
            Spacer()

            Menu {
                Toggle("Restart ChatGPT after switching", isOn: setting(\.restartChatGPT))
                Toggle("Refresh automatically every 2 minutes", isOn: setting(\.autoRefresh))
                Toggle("Show 5-hour remaining quota in menu bar", isOn: setting(\.showMenuBarUsage))
                Toggle("Hide email addresses", isOn: setting(\.hideEmails))
                Divider()
                if let updater = model.updater {
                    UpdateSettingsMenu(updater: updater)
                    Divider()
                }
                Text("Shortcuts: ⌘F Search · ⌘N Add · ⌘R Refresh")
                Divider()
                Button("Quit Codex Profiles") { model.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(minHeight: 28)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Codex Profiles settings")
            .disabled(model.isBusy || model.pendingNewLogin)
        }
        .font(PanelDS.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.35)
        }
    }

    /// Compact relative time for the footer. The built-in relative style rendered
    /// awkward strings such as "1 sec" in a narrow menu bar panel.
    private func lastCheckText(_ checked: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(checked)
        if elapsed < 5 { return "just now" }
        if elapsed < 60 { return "\(max(1, Int(elapsed)))s ago" }
        if elapsed < 3_600 { return "\(max(1, Int(elapsed / 60)))m ago" }
        return UsageWindow.compactDuration(elapsed) + " ago"
    }

    private func profileAccessibilityLabel(_ profile: Profile, active: Bool) -> String {
        let subtitle = profile.identity?.subtitle ?? ""
        let state = active ? "active account" : "saved account"
        return [model.displayName(for: profile), subtitle, state]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: {
                model.settings[keyPath: keyPath] = $0
                model.updateSettings()
            }
        )
    }
}
