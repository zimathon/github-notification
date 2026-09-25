import XCTest
@testable import NotificationCore

final class SignalPreviewTests: XCTestCase {
    func testHidesBotMetadataWithoutDiscardingVisibleText() {
        XCTAssertEqual(SignalPreview.text("<!-- bot marker -->\n## Deploy ready\n[Preview](https://example.com)"), "Deploy ready · Preview")
        XCTAssertEqual(SignalPreview.text("[vc]: #encoded-payload\nDeployment failed"), "Deployment failed")
        XCTAssertEqual(SignalPreview.text("<!-- truncated metadata"), "")
    }

    func testKeepsSeverityAndCodeMeaningInReview() {
        let source = "**<sub>![P1 Badge](https://example.com/p1)</sub> Fix redirect**\nUse `origin` &amp; keep the cookie."
        XCTAssertEqual(SignalPreview.text(source), "P1 Badge Fix redirect · Use origin & keep the cookie.")
    }

    func testApprovalLabelUsesStoredReviewStateWithoutChangingNotificationKind() throws {
        func signal(_ id: String, kind: SignalKind = .review) -> Signal {
            Signal(id: id, kind: kind, repository: "org/repo", title: "PR", actor: "other", excerpt: "Approveという文字を含む任意の本文", url: "https://github.com/org/repo/pull/1", date: Date())
        }
        let approval = signal("review:123:APPROVED")
        // A previously saved notification needs no migration or API refetch.
        let restored = try JSONDecoder().decode(Signal.self, from: JSONEncoder().encode(approval))
        XCTAssertEqual(restored.kindLabel, "PRが承認された")
        XCTAssertEqual(restored.kind, .review)
        let mentionedApproval = signal("review:123:APPROVED", kind: .mention)
        XCTAssertEqual(mentionedApproval.kindLabel, "PRが承認された")
        XCTAssertEqual(mentionedApproval.kind, .mention)
        for id in ["review:123:COMMENTED", "review:123:CHANGES_REQUESTED", "review:123:DISMISSED", "comment:123:APPROVED", "request:123", "review::APPROVED"] {
            XCTAssertFalse(signal(id).isApproval, id)
            XCTAssertEqual(signal(id).kindLabel, SignalKind.review.title)
        }
    }

    func testOpeningAcknowledgesOnlyTheRequestedScopeAfterSuccessfulHandoff() {
        let first = Signal(id: "one", kind: .comment, repository: "org/repo", title: "PR", actor: "other", excerpt: "body", url: "https://github.com/org/repo/pull/1#one", date: Date())
        var second = first; second.id = "two"; second.url = "https://github.com/org/repo/pull/1#two"
        var other = first; other.id = "other"; other.url = "https://github.com/org/repo/pull/2"
        var state = InboxState(); state.signals = [first, second, other]
        XCTAssertTrue(state.openSignal("one", entireThread: true, using: { _ in false }).isEmpty)
        XCTAssertTrue(state.signals.allSatisfy { !$0.acknowledged })
        XCTAssertEqual(state.openSignal("one", entireThread: false, using: { $0.fragment == "one" }), ["one"])
        XCTAssertFalse(state.signals[1].acknowledged)
        XCTAssertEqual(state.openSignal("one", entireThread: true, using: { _ in true }), ["two"])
        XCTAssertFalse(state.signals[2].acknowledged)
        state.signals[2].url = "file:///tmp/test"
        var called = false
        XCTAssertTrue(state.openSignal("other", entireThread: true, using: { _ in called = true; return true }).isEmpty)
        XCTAssertFalse(called)
        XCTAssertFalse(state.signals[2].acknowledged)
    }

    func testGroupsCommentsReviewsAndFileLinksByPRNotTitle() {
        func signal(_ url: String) -> Signal {
            Signal(id: url, kind: .comment, repository: "org/repo", title: "Same title", actor: "other", excerpt: "body", url: url, date: Date())
        }
        let first = signal("https://github.com/org/repo/pull/12#issuecomment-1")
        XCTAssertEqual(first.threadKey, signal("https://github.com/org/repo/pull/12/files?diff=split#discussion_r2").threadKey)
        XCTAssertEqual(first.threadKey, signal("https://github.com/org/repo/pull/12#pullrequestreview-3").threadKey)
        XCTAssertNotEqual(first.threadKey, signal("https://github.com/org/repo/pull/13").threadKey)
        XCTAssertNotEqual(first.threadKey, signal("https://github.com/org/other/pull/12").threadKey)
    }
}
