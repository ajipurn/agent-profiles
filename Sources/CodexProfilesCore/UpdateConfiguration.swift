import Foundation

public struct UpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicKey: String

    public init?(feedURL: String?, publicKey: String?) {
        guard let feedURL, let url = URL(string: feedURL),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              let publicKey, let key = Data(base64Encoded: publicKey), key.count == 32
        else { return nil }
        self.feedURL = url
        self.publicKey = publicKey
    }
}
