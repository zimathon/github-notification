import XCTest
@testable import NotificationCore

final class PullRequestAuthorFilterTests: XCTestCase {
    private var signal: Signal {
        Signal(id: "comment", kind: .mention, repository: "org/repo", title: "PR", actor: "other",
               excerpt: "@me", url: "https://github.com/org/repo/pull/1#issuecomment-1", date: Date())
    }

    func testAuthorRatherThanCommentActorDeterminesOwnership() {
        let mine = PullRequestInfo(state: "open", draft: false, merged: false, author: "ME")
        let other = PullRequestInfo(state: "closed", draft: false, merged: true, author: "teammate")
        for (info, isMine) in [(mine, true), (other, false)] {
            XCTAssertEqual(PullRequestAuthorFilter.mine.includes(signal, info: info, account: "me"), isMine)
            XCTAssertEqual(PullRequestAuthorFilter.others.includes(signal, info: info, account: "me"), !isMine)
        }
    }

    func testUnknownAuthorsAccountsAndIssuesOnlyAppearInAll() {
        let known = PullRequestInfo(state: "open", draft: false, merged: false, author: "other")
        let unknown = PullRequestInfo(state: "open", draft: false, merged: false)
        var issue = signal; issue.url = "https://github.com/org/repo/issues/1"
        for (item, info, account) in [(signal, nil, "me"), (signal, unknown, "me"),
                                      (signal, known, nil), (signal, known, ""), (issue, known, "me")] as [(Signal, PullRequestInfo?, String?)] {
            XCTAssertTrue(PullRequestAuthorFilter.all.includes(item, info: info, account: account))
            XCTAssertFalse(PullRequestAuthorFilter.mine.includes(item, info: info, account: account))
            XCTAssertFalse(PullRequestAuthorFilter.others.includes(item, info: info, account: account))
        }
    }

    func testOldCacheDecodesAndAuthorSurvivesRoundTrip() throws {
        let old = try JSONDecoder().decode(PullRequestInfo.self, from: Data(#"{"status":"open","checkedAt":0}"#.utf8))
        XCTAssertNil(old.author)
        XCTAssertEqual(old.status, "open")
        var updated = old; updated.author = "me"
        XCTAssertEqual(try JSONDecoder().decode(PullRequestInfo.self, from: JSONEncoder().encode(updated)), updated)
    }

    func testRefreshCapturesPRCreator() async throws {
        let client = GitHubClient(transport: AuthorTransport())
        let info = try await client.pullRequest(for: signal)
        XCTAssertEqual(info.author, "me")
        XCTAssertTrue(PullRequestAuthorFilter.mine.includes(signal, info: info, account: "me"))
    }
}

private struct AuthorTransport: GitHubTransport {
    func get(_ path: String) async throws -> APIResponse {
        APIResponse(data: Data(#"{"title":"PR","user":{"login":"me"},"html_url":"https://github.com/org/repo/pull/1","updated_at":"2026-09-17T12:00:00Z","state":"open"}"#.utf8))
    }
}
