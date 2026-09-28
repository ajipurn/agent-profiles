import AppKit
import Combine
import CodexProfilesCore
import Sparkle
import SwiftUI

@MainActor
public final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var automaticallyChecks = false
    @Published public private(set) var automaticallyInstalls = false
    @Published public private(set) var unavailableReason: String?

    private var controller: SPUStandardUpdaterController?
    private let canRelaunch: () -> Bool
    private var deferredRelaunch: Task<Void, Never>?

    public var isAvailable: Bool { controller != nil && unavailableReason == nil }

    public init(enabled: Bool, canRelaunch: @escaping () -> Bool) {
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

    public func checkForUpdates() {
        guard canCheckForUpdates, canRelaunch() else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    public func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    public func setAutomaticInstallation(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard canRelaunch() else {
            throw NSError(domain: "dev.aji.AgentProfiles.Update", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Finish the current account operation before updating the app.",
            ])
        }
    }

    public func updater(
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
