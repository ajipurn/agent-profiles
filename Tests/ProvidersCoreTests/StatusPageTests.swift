import Foundation
import Testing
@testable import ProvidersCore

@Suite struct StatusPageTests {
    let base = URL(string: "https://status.example.com")!

    @Test func allClearIsNil() {
        let object: [String: Any] = ["status": ["indicator": "none", "description": "All Systems Operational"],
                                     "incidents": []]
        #expect(StatusPage.parse(object, base: base) == nil)
    }

    @Test func openIncidentNamesIt() {
        let object: [String: Any] = [
            "page": ["url": "https://status.example.com"],
            "status": ["indicator": "major", "description": "Partial System Outage"],
            "incidents": [["name": "Elevated errors on Opus", "status": "investigating"],
                          ["name": "Old", "status": "resolved"]],
        ]
        let incident = StatusPage.parse(object, base: base)
        #expect(incident?.title == "Elevated errors on Opus")
        #expect(incident?.isMajor == true)
    }

    @Test func maintenanceInProgress() {
        let object: [String: Any] = ["status": ["indicator": "none"],
                                     "scheduled_maintenances": [["name": "DB upgrade", "status": "in_progress"]]]
        #expect(StatusPage.parse(object, base: base)?.level == .maintenance)
    }
}
