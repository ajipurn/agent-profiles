import Foundation

public protocol CodexClientController: Sendable {
    func stopForSwitch(restartChatGPT: Bool, restartEditorServer: Bool) async
    func startAfterSwitch(restartChatGPT: Bool) async
}

public final class NullCodexClients: CodexClientController, @unchecked Sendable {
    public var stopCount = 0
    public var startCount = 0

    public init() {}

    public func stopForSwitch(restartChatGPT: Bool, restartEditorServer: Bool) async {
        stopCount += 1
    }

    public func startAfterSwitch(restartChatGPT: Bool) async {
        startCount += 1
    }
}
