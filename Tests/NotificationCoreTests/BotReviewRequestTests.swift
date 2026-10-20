import XCTest
@testable import NotificationCore

final class BotReviewRequestTests: XCTestCase {
    private func signal(_ url: String) -> Signal {
        Signal(id: url, kind: .comment, repository: "org/repo", title: "PR", actor: "someone",
               excerpt: "", url: url, date: Date())
    }

    func testPlanDeduplicatesCommentsAndKeepsBothBotsSeparate() {
        let signals = [signal("https://github.com/org/repo/pull/42#issuecomment-1"),
                       signal("https://github.com/org/repo/pull/42/files?diff=1#discussion-2"),
                       signal("https://github.com/org/repo/issues/3"),
                       signal("https://github.com/org/repo/pull/43")]
        let plan = BotReviewRequest.plan(signals: signals, bots: [.codex, .claude])
        XCTAssertEqual(plan.count, 4)
        XCTAssertEqual(plan[0].path, "/repos/org/repo/issues/42/comments")
        XCTAssertEqual(plan[0].url.absoluteString, "https://github.com/org/repo/pull/42")
        XCTAssertEqual(plan[0].body, "@codex review")
        XCTAssertTrue(plan[1].body.hasPrefix("@claude "))
        XCTAssertTrue(plan[1].body.contains("コードの変更やcommit・pushは行わず"))
        XCTAssertEqual(Set(plan.map(\.id)).count, 4)
        XCTAssertEqual(BotReviewRequest.plan(signals: signals, bots: [.claude]).count, 2)
        XCTAssertTrue(BotReviewRequest.plan(signals: signals, bots: []).isEmpty)
    }

    func testRejectsNonPRsAndUnsafeWriteEndpoints() {
        for url in ["https://evil.test/org/repo/pull/1", "http://github.com/org/repo/pull/1",
                    "https://github.com/org/repo/issues/1", "https://github.com/org/repo/pull/nope",
                    "https://me@github.com/org/repo/pull/1", "https://github.com:443/org/repo/pull/1"] {
            XCTAssertNil(BotReviewRequest(signal: signal(url), bot: .codex), url)
        }
        for path in ["/repos/../repo/issues/1/comments", "/repos/org/./issues/1/comments", "//evil.test", "/repos/org/repo/pulls/1/comments", "/repos/org/repo/issues/1/comments\n", "/repos/org/repo/issues/1/comments?x=1"] {
            XCTAssertFalse(BotReviewRequest.isCommentPath(path), path)
        }
    }

    func testAccountIsVerifiedBeforeEveryWrite() async throws {
        let transport = AccountReviewTransport(logins: ["ME", "other"])
        let client = BotReviewClient(transport: transport)
        let request = try XCTUnwrap(BotReviewRequest(signal: signal("https://github.com/org/repo/pull/1"), bot: .codex))
        try await client.send(request, account: "me")
        do {
            try await client.send(request, account: "me")
            XCTFail("Expected account mismatch")
        } catch BotReviewError.accountMismatch { }
        let count = await transport.posts
        XCTAssertEqual(count, 1)
    }

    func testFailedAccountVerificationNeverWrites() async throws {
        let transport = AccountReviewTransport(logins: [])
        let request = try XCTUnwrap(BotReviewRequest(signal: signal("https://github.com/org/repo/pull/1"), bot: .codex))
        do {
            try await BotReviewClient(transport: transport).send(request, account: "me")
            XCTFail("Expected account verification failure")
        } catch BotReviewError.accountVerificationFailed { }
        let count = await transport.posts
        XCTAssertEqual(count, 0)
    }

    func testTransportRejectsOtherWriteTargetsBeforeLaunchingCLI() async {
        do {
            _ = try await GHTransport().postComment("/user", body: "@codex review")
            XCTFail("Expected invalid target")
        } catch {
            XCTAssertEqual(error.localizedDescription, "レビュー依頼先が正しくありません。")
        }
    }

    func testFailureIsNotRetriedAndNextBotCanStillBeSent() async throws {
        let transport = RecordingReviewTransport()
        let client = BotReviewClient(transport: transport)
        let plan = BotReviewRequest.plan(signals: [signal("https://github.com/org/repo/pull/1")], bots: [.codex, .claude])
        do { try await client.send(plan[0], account: "me"); XCTFail("Expected failure") } catch { }
        try await client.send(plan[1], account: "me")
        let bodies = await transport.bodies
        XCTAssertEqual(bodies, plan.map(\.body))
    }
}

private actor RecordingReviewTransport: ReviewCommentTransport {
    var bodies: [String] = []
    func get(_ path: String) async throws -> APIResponse { APIResponse(data: Data(#"{"login":"ME"}"#.utf8)) }
    func postComment(_ path: String, body: String) async throws -> APIResponse {
        bodies.append(body)
        if bodies.count == 1 { throw SignalError.message("Timeout") }
        return APIResponse(data: Data("{}".utf8), headers: [:])
    }
}

private actor AccountReviewTransport: ReviewCommentTransport {
    var logins: [String]
    var posts = 0
    init(logins: [String]) { self.logins = logins }
    func get(_ path: String) async throws -> APIResponse {
        guard !logins.isEmpty else { throw SignalError.message("Disconnected") }
        return APIResponse(data: try JSONEncoder().encode(["login": logins.removeFirst()]))
    }
    func postComment(_ path: String, body: String) async throws -> APIResponse {
        posts += 1
        return APIResponse(data: Data("{}".utf8))
    }
}
