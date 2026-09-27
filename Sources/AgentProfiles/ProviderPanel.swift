import SwiftUI
import CodexProfilesUI

/// The popover content: one tab per provider, each hosting that provider's
/// panel as it was in its original app. A shared design comes later.
struct ProviderPanel: View {
    enum Provider: String, CaseIterable, Identifiable {
        case claude = "Claude"
        case codex = "Codex"
        var id: String { rawValue }
    }

    let claude: AppState
    let codex: AppModel
    @AppStorage("selectedProvider") private var provider: Provider = .claude

    var body: some View {
        VStack(spacing: 0) {
            Picker("Provider", selection: $provider) {
                ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch provider {
            case .claude:
                PanelView(state: claude)
            case .codex:
                MenuPanel().environment(codex)
            }
        }
        .fixedSize()
    }
}
