import AppKit
import Combine
import CodexProfilesCore
import Sparkle
import SwiftUI

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyInstalls = false
    @Published private(set) var unavailableReason: String?

    private var controller: SPUStandardUpdaterController?
    private let canRelaunch: () -> Bool
    private var deferredRelaunch: Task<Void, Never>?

    var isAvailable: Bool { controller != nil && unavailableReason == nil }

    init(enabled: Bool, canRelaunch: @escaping () -> Bool) {
        self.canRelaunch = canRelaunch
        super.init()
        guard enabled else {
            unavailableReason = "App updates are disabled in preview mode."
            return
        }
        guard Bundle.main.bundleURL.pathExtension == "app",
              UpdateConfiguration(
                feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
              ) != nil
        else {
            unavailableReason = "Install a release build to enable app updates."
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyInstalls)
        do {
            try updater.start()
        } catch {
            unavailableReason = "Unable to start app updates: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates, canRelaunch() else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticInstallation(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard canRelaunch() else {
            throw NSError(domain: "dev.aji.CodexProfiles.Update", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Finish the current account operation before updating the app.",
            ])
        }
    }

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard !canRelaunch() else { return false }
        deferredRelaunch?.cancel()
        deferredRelaunch = Task { @MainActor [weak self] in
            while let self, !self.canRelaunch() {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard self != nil, !Task.isCancelled else { return }
            installHandler()
        }
        return true
    }
}

struct UpdateSettingsMenu: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        Toggle("Automatically check for app updates", isOn: Binding(
            get: { updater.automaticallyChecks }, set: { updater.setAutomaticChecks($0) }
        ))
        .disabled(!updater.isAvailable)
        Toggle("Automatically download and install updates", isOn: Binding(
            get: { updater.automaticallyInstalls }, set: { updater.setAutomaticInstallation($0) }
        ))
        .disabled(!updater.isAvailable || !updater.automaticallyChecks)
        if let reason = updater.unavailableReason {
            Text(reason)
        }
        if let repository = Bundle.main.object(forInfoDictionaryKey: "CPRepositoryURL") as? String,
           let url = URL(string: repository + "/releases"), url.scheme == "https" {
            Button("View GitHub releases…") { NSWorkspace.shared.open(url) }
        }
        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
    }
}
