import XCTest
@testable import NotificationCore

final class AcknowledgementUndoTests: XCTestCase {
    private func signal(_ id: String, pr: Int = 1) -> Signal {
        Signal(id: id, kind: .mention, repository: "org/repo", title: "PR", actor: "other", excerpt: "@you", url: "https://github.com/org/repo/pull/\(pr)", date: .distantPast)
    }
    func testUndoPreservesNewArrivalsAndAlreadyAcknowledgedItems() {
        var state = InboxState()
        var seen = signal("seen"); seen.acknowledged = true
        state.signals = [signal("old"), seen]
        state.acknowledgeThreads([state.signals[0].threadKey])
        state.merge([signal("new")])
        XCTAssertTrue(state.undoAcknowledgement())
        XCTAssertFalse(state.signals.first { $0.id == "old" }!.acknowledged)
        XCTAssertFalse(state.signals.first { $0.id == "new" }!.acknowledged)
        XCTAssertTrue(state.signals.first { $0.id == "seen" }!.acknowledged)
    }
    func testUndoRestoresPrunedBodyAndNoopDoesNotConsumeHistory() throws {
        var state = InboxState(); state.signals = [signal("body:1:hash")]
        state.acknowledgeSignals(["body:1:hash"])
        state.acknowledgeSignals(["body:1:hash"])
        state.prune(before: Date())
        XCTAssertTrue(state.signals.isEmpty)
        XCTAssertTrue(state.undoAcknowledgement())
        XCTAssertEqual(state.signals.count, 1)
        XCTAssertFalse(state.signals[0].acknowledged)
        XCTAssertFalse(state.acknowledgedBodyIDs.contains("body:1:hash"))
        XCTAssertFalse(state.canUndoAcknowledgement)
        state.acknowledgeSignals(["body:1:hash"])
        let reloaded = try JSONDecoder().decode(InboxState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(reloaded.canUndoAcknowledgement)
        XCTAssertTrue(reloaded.signals[0].acknowledged)
    }
    func testUndoLimitAndBrowserNavigation() {
        var state = InboxState()
        for number in 1...21 {
            let item = signal("item:\(number)", pr: number); state.signals.append(item)
            state.acknowledgeSignals([item.id])
        }
        _ = state.openSignal("item:21", entireThread: true) { _ in true }
        for _ in 1...20 { XCTAssertTrue(state.undoAcknowledgement()) }
        XCTAssertFalse(state.undoAcknowledgement())
        XCTAssertEqual(state.signals.filter(\.acknowledged).map(\.id), ["item:1"])
    }
    func testStarsPersistAndProtectAcknowledgedThreadsFromPruning() throws {
        var state = InboxState()
        let kept = signal("kept"), removed = signal("removed", pr: 2)
        state.signals = [kept, removed]
        state.starredThreads.insert(kept.threadKey)
        state.acknowledgeThreads([kept.threadKey, removed.threadKey])
        state.prune(before: Date())
        XCTAssertEqual(state.signals.map(\.id), ["kept"])
        var restored = try JSONDecoder().decode(InboxState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.starredThreads, [kept.threadKey])
        restored.starredThreads.remove(kept.threadKey)
        restored.prune(before: Date())
        XCTAssertTrue(restored.signals.isEmpty)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        legacy.removeValue(forKey: "starredThreads")
        let migrated = try JSONDecoder().decode(InboxState.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(migrated.starredThreads.isEmpty)
    }

}
