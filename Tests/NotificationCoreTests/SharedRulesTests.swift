import XCTest
@testable import NotificationCore

final class SharedRulesTests: XCTestCase {
    func testWindowsAndMacUseTheSameNotificationRules() throws {
        struct Fixture: Decodable {
            struct Mention: Decodable { let body: String; let login: String; let expected: Bool }
            struct Classification: Decodable { let body: String; let actor: String; let ownPR: Bool; let review: Bool; let expected: String? }
            let mentions: [Mention]
            let classification: [Classification]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/fixtures/notification-rules.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        for item in fixture.mentions {
            XCTAssertEqual(SignalRules.mentions(item.body, login: item.login), item.expected, item.body)
        }
        for item in fixture.classification {
            XCTAssertEqual(SignalRules.kind(body: item.body, actor: item.actor, login: "zimathon", ownPR: item.ownPR, isReview: item.review)?.rawValue, item.expected)
        }
    }
}
