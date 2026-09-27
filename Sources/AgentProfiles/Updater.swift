import SwiftUI
import CodexProfilesUI

/// The Claude screens still talk to `Updater.shared`. In the merged app it is
/// a thin view onto the single Sparkle controller the app delegate owns, so
/// the Claude and Codex update settings drive the same updater.
///
/// Nil while updates are unavailable (preview mode, or a build without a
/// feed and public key).
@MainActor
final class Updater {
    static var shared: Updater?

    private let controller: UpdateController

    init(controller: UpdateController) {
        self.controller = controller
    }

    /// Two-way binding for the Settings toggle — Sparkle persists this itself.
    var automaticChecks: Binding<Bool> {
        Binding(get: { self.controller.automaticallyChecks },
                set: { self.controller.setAutomaticChecks($0) })
    }

    func checkForUpdates() {
        controller.checkForUpdates()
    }
}
