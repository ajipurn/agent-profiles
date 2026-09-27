import AppKit
import Foundation
import CodexProfilesCore

struct SystemCodexClients: CodexClientController {
    static let chatGPTBundleID = "com.openai.codex"

    func stopForSwitch(restartChatGPT: Bool, restartEditorServer: Bool) async {
        guard restartChatGPT else { return }
        terminateChatGPT()
        await waitUntilChatGPTExits(seconds: 8)
    }

    func startAfterSwitch(restartChatGPT: Bool) async {
        guard restartChatGPT else { return }
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chatGPTBundleID)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chatgpt")
            ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    func terminateChatGPT() {
        for app in runningChatGPT() {
            app.terminate()
        }
    }

    func runningChatGPT() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.chatGPTBundleID)
            + NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.chatgpt")
    }

    func waitUntilChatGPTExits(seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard !Task.isCancelled else { return }
            if runningChatGPT().isEmpty { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        for app in runningChatGPT() {
            app.forceTerminate()
        }
    }
}
