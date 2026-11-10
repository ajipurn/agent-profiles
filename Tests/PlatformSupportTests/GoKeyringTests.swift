import Foundation
import Testing
@testable import PlatformSupport

struct GoKeyringTests {
    @Test func decodesGoKeyringForms() {
        let json = #"{"token":{"access_token":"a"}}"#
        #expect(GoKeyring.decode("go-keyring-base64:" + Data(json.utf8).base64EncodedString()) == json)
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(GoKeyring.decode("go-keyring-encoded:" + hex) == json)
        #expect(GoKeyring.decode(json) == json)
    }

    @Test func encodesAsGoKeyringDoes() {
        let json = #"{"token":{"access_token":"a'b"}}"#
        let stored = GoKeyring.encode(json)
        #expect(stored.hasPrefix("go-keyring-base64:"))
        #expect(!stored.contains("'"))
        #expect(GoKeyring.decode(stored) == json)
    }

    @Test func rejectsMalformedEncodings() {
        #expect(GoKeyring.decode("go-keyring-base64:%%%") == nil)
        #expect(GoKeyring.decode("go-keyring-encoded:zz") == nil)
    }
}
