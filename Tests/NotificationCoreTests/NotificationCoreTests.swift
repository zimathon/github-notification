import XCTest
@testable import NotificationCore

final class NotificationCoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_789_603_200)

    func testMentionBoundariesAndSelfExclusion() {
        XCTAssertTrue(SignalRules.mentions("確認 @ZiMaThOn お願い", login: "zimathon"))
        for value in ["@zimathon-dev", "@zimathon_dev", "@zimathon/team", "mail@zimathon", "@@zimathon"] {
            XCTAssertFalse(SignalRules.mentions(value, login: "zimathon"), value)
        }
        XCTAssertNil(SignalRules.kind(body: "@zimathon", actor: "ZIMATHON", login: "zimathon", ownPR: true, isReview: false))
        XCTAssertNil(SignalRules.kind(body: "LGTM", actor: "other", login: "zimathon", ownPR: false, isReview: true))
        XCTAssertEqual(SignalRules.kind(body: "LGTM", actor: "other", login: "zimathon", ownPR: true, isReview: true), .review)
    }

    func testMergePreservesAcknowledgementAndAllowsNewCommentRevision() {
        var state = InboxState()
        var existing = signal("comment:1:v1")
        existing.acknowledged = true
        state.merge([existing])
        state.merge([signal("comment:1:v1"), signal("comment:1:v2"), signal("comment:1:v2")])
        XCTAssertEqual(state.signals.count, 2)
        XCTAssertTrue(state.signals.first(where: { $0.id == existing.id })!.acknowledged)
        XCTAssertFalse(state.signals.first(where: { $0.id == "comment:1:v2" })!.acknowledged)
    }

    func testReminderAndSnooze() {
        var item = signal("1")
        XCTAssertTrue(item.needsNotification(at: now, reminderMinutes: 30))
        item.lastNotifiedAt = now
        XCTAssertFalse(item.needsNotification(at: now.addingTimeInterval(1799), reminderMinutes: 30))
        XCTAssertTrue(item.needsNotification(at: now.addingTimeInterval(1800), reminderMinutes: 30))
        XCTAssertFalse(item.needsNotification(at: now.addingTimeInterval(9999), reminderMinutes: 0))
        item.snoozedUntil = now.addingTimeInterval(3600)
        item.lastNotifiedAt = nil
        XCTAssertFalse(item.needsNotification(at: now, reminderMinutes: 0))
        XCTAssertTrue(item.needsNotification(at: now.addingTimeInterval(3600), reminderMinutes: 0))
        item.acknowledged = true
        XCTAssertFalse(item.needsNotification(at: now.addingTimeInterval(9999), reminderMinutes: 30))
    }

    func testAcknowledgedBodyMentionStaysDeduplicatedAfterHistoryPruning() {
        var state = InboxState()
        var body = signal("body:thread:digest")
        body.acknowledged = true
        state.merge([body])
        state.prune(before: now.addingTimeInterval(8 * 86_400))
        XCTAssertTrue(state.signals.isEmpty)
        XCTAssertTrue(state.acknowledgedBodyIDs.contains(body.id))
        var revived = body
        revived.acknowledged = false
        revived.date = now.addingTimeInterval(9 * 86_400)
        state.merge([revived])
        XCTAssertTrue(state.signals.isEmpty)
        state.merge([signal("body:thread:changed-digest")])
        XCTAssertEqual(state.signals.count, 1)
    }

    func testExistingInboxBeforeBodyTombstonesLoadsWithoutLosingData() throws {
        var state = InboxState()
        state.enabled = true
        state.account = "me"
        state.merge([signal("1")])
        let data = try JSONEncoder().encode(state)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "acknowledgedBodyIDs")
        var settings = json["settings"] as! [String: Any]
        settings.removeValue(forKey: "organizations")
        json["settings"] = settings
        let migrated = try JSONDecoder().decode(InboxState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.account, "me")
        XCTAssertTrue(migrated.enabled)
        XCTAssertEqual(migrated.signals.map(\.id), ["1"])
        XCTAssertTrue(migrated.acknowledgedBodyIDs.isEmpty)
        XCTAssertTrue(migrated.settings.organizations.isEmpty)
    }

    func testOrganizationFilterMatchesOwnerExactlyAndRestoresAllWhenEmpty() throws {
        var settings = Settings()
        XCTAssertTrue(settings.includes(repository: "any/repo"))
        settings.organizations = try Settings.parseOrganizations(" Acme, example-org、ACME\nmy-user ")
        XCTAssertEqual(settings.organizations, ["acme", "example-org", "my-user"])
        XCTAssertTrue(settings.includes(repository: "ACME/private-repo"))
        XCTAssertTrue(settings.includes(repository: "my-user/repo"))
        XCTAssertFalse(settings.includes(repository: "acme-other/repo"))
        XCTAssertFalse(settings.includes(repository: "other/acme"))
        XCTAssertThrowsError(try Settings.parseOrganizations("https://github.com/acme"))
        XCTAssertThrowsError(try Settings.parseOrganizations("acme/repo"))
        settings.organizations = try Settings.parseOrganizations(" , \n")
        XCTAssertTrue(settings.includes(repository: "other/repo"))
    }

    func testQueueIsDurableAndRetainsFailedThreadsEarliestBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(url: directory.appendingPathComponent("state.json"))
        var state = InboxState()
        let thread = try decodeThread()
        state.enqueue([thread], since: now.addingTimeInterval(-3600), cursor: now)
        state.enqueue([thread], since: now.addingTimeInterval(-300), cursor: now.addingTimeInterval(60))
        state.merge([signal("1")])
        state.signals[0].snoozedUntil = now.addingTimeInterval(3600)
        try store.save(state)
        let loaded = try store.load()
        XCTAssertEqual(loaded.pending[thread.id]?.since, now.addingTimeInterval(-3600))
        XCTAssertEqual(loaded.cursor, now.addingTimeInterval(60))
        XCTAssertEqual(loaded.signals[0].snoozedUntil, now.addingTimeInterval(3600))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue, 0o600)
        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }

    func testUnchangedThreadsAreSkippedButUpdatesAreQueued() throws {
        var state = InboxState()
        var thread = try decodeThread()
        state.processed[thread.id] = thread.updatedAt
        state.enqueue([thread], since: now, cursor: now)
        XCTAssertTrue(state.pending.isEmpty)
        thread.updatedAt.addTimeInterval(1)
        state.enqueue([thread], since: now, cursor: now)
        XCTAssertEqual(state.pending.count, 1)
    }

    func testOnlyGitHubHTTPSLinksCanBeOpened() {
        XCTAssertNotNil(SignalRules.safeWebURL("https://github.com/org/repo/pull/1#discussion_r2"))
        for url in ["http://github.com/a", "https://github.com.evil.test/a", "file:///etc/passwd", "https://user@github.com/a", "https://github.com:8443/a"] {
            XCTAssertNil(SignalRules.safeWebURL(url), url)
        }
    }

    func testGHResponseParsingFailsClosed() throws {
        let valid = "HTTP/2.0 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nX-Poll-Interval: 120\r\n\r\n[]"
        let response = try GHTransport.parse(Data(valid.utf8), exitCode: 0)
        XCTAssertEqual(response.headers["x-poll-interval"], "120")
        XCTAssertEqual(String(data: response.data, encoding: .utf8), "[]")
        XCTAssertThrowsError(try GHTransport.parse(Data(valid.utf8), exitCode: 1))
        XCTAssertThrowsError(try GHTransport.parse(Data("please login".utf8), exitCode: 1))
        XCTAssertThrowsError(try GHTransport.parse(Data("HTTP/2.0 403 Forbidden\nContent-Type: application/json\n\n{}".utf8), exitCode: 1))
        XCTAssertThrowsError(try GHTransport.parse(Data("HTTP/2.0 200 OK\nContent-Type: text/html\n\n<html/>".utf8), exitCode: 0))
    }

    func testNotificationPaginationAndServerTime() async throws {
        let transport = StubTransport(responses: [
            APIResponse(data: Data("[\(threadJSON)]".utf8), headers: ["date": "Thu, 17 Sep 2026 12:00:00 GMT", "link": "<ignored>; rel=\"next\"", "x-poll-interval": "180"]),
            APIResponse(data: Data("[]".utf8))
        ])
        let batch = try await GitHubClient(transport: transport).notifications(since: now)
        XCTAssertEqual(batch.threads.count, 1)
        XCTAssertEqual(batch.pollInterval, 180)
        XCTAssertEqual(ISO8601DateFormatter().string(from: batch.serverDate), "2026-09-17T12:00:00Z")
        let paths = await transport.paths
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[1].hasSuffix("page=2"))
    }

    func testPaginationFailureIsNotAnEmptySuccess() async throws {
        let transport = StubTransport(responses: [
            APIResponse(data: Data("[]".utf8), headers: ["date": "Thu, 17 Sep 2026 12:00:00 GMT", "link": "<ignored>; rel=\"next\""])
        ])
        do {
            _ = try await GitHubClient(transport: transport).notifications(since: now)
            XCTFail("A missing page must fail the batch")
        } catch { XCTAssertTrue(error is SignalError) }
    }

    func testOwnPRUsesActualAuthorRegardlessOfNotificationReason() async throws {
        let transport = StubTransport(responses: subjectResponses(owner: "me", body: "No mention", comments: "[{\"id\":3,\"body\":\"Please check\",\"user\":{\"login\":\"other\"},\"html_url\":\"https://github.com/org/repo/pull/1#issuecomment-3\",\"updated_at\":\"2026-09-17T12:00:00Z\"}]"))
        let pending = PendingThread(thread: try decodeThread(), since: Date(timeIntervalSince1970: 0))
        let signals = try await GitHubClient(transport: transport).signals(for: pending, login: "me")
        XCTAssertEqual(signals.map(\.kind), [.comment])
    }

    func testStickyMentionReasonDoesNotNotifyUnrelatedComment() async throws {
        let transport = StubTransport(responses: subjectResponses(owner: "other", body: "No mention", comments: "[{\"id\":3,\"body\":\"Unrelated\",\"user\":{\"login\":\"other\"},\"html_url\":\"https://github.com/org/repo/pull/1#issuecomment-3\",\"updated_at\":\"2026-09-17T12:00:00Z\"}]"))
        let pending = PendingThread(thread: try decodeThread(), since: Date(timeIntervalSince1970: 0))
        let signals = try await GitHubClient(transport: transport).signals(for: pending, login: "me")
        XCTAssertTrue(signals.isEmpty)
    }

    func testRepeatedReviewRequestsHaveDistinctIDs() async throws {
        var responses = subjectResponses(owner: "other", body: "No mention", comments: "[]")
        responses[4] = APIResponse(data: Data("[{\"id\":11,\"event\":\"review_requested\",\"actor\":{\"login\":\"other\"},\"requested_reviewer\":{\"login\":\"me\"},\"created_at\":\"2026-09-17T12:00:00Z\"},{\"id\":12,\"event\":\"review_requested\",\"actor\":{\"login\":\"other\"},\"requested_reviewer\":{\"login\":\"me\"},\"created_at\":\"2026-09-17T12:01:00Z\"}]".utf8))
        let signals = try await GitHubClient(transport: StubTransport(responses: responses)).signals(
            for: PendingThread(thread: try decodeThread(), since: Date(timeIntervalSince1970: 0)), login: "me")
        XCTAssertEqual(signals.map(\.id), ["request:11", "request:12"])
        XCTAssertTrue(signals.allSatisfy { $0.kind == .reviewRequest })
    }

    func testBodyMentionDoesNotDuplicateWhenOnlyThreadTimestampChanges() async throws {
        let first = subjectResponses(owner: "other", body: "@me check", comments: "[]")
        var second = first
        second[0] = APIResponse(data: Data(String(data: first[0].data, encoding: .utf8)!.replacingOccurrences(of: "12:00:00", with: "12:10:00").utf8))
        let pending = PendingThread(thread: try decodeThread(), since: Date(timeIntervalSince1970: 0))
        let a = try await GitHubClient(transport: StubTransport(responses: first)).signals(for: pending, login: "me")
        let b = try await GitHubClient(transport: StubTransport(responses: second)).signals(for: pending, login: "me")
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        XCTAssertEqual(a.first?.kind, .mention)
    }

    func testUntrustedAPISubjectIsRejectedBeforeTransport() async throws {
        var thread = try decodeThread()
        thread.subject.url = "https://evil.test/repos/org/repo/pulls/1"
        let transport = StubTransport(responses: [])
        do {
            _ = try await GitHubClient(transport: transport).signals(for: PendingThread(thread: thread, since: now), login: "me")
            XCTFail("Untrusted host must fail")
        } catch { XCTAssertTrue(error is SignalError) }
        let paths = await transport.paths
        XCTAssertTrue(paths.isEmpty)
    }

    func testPRStatusUpdatesWithoutNewSignalsAndPreservesAcknowledgement() async throws {
        var state = InboxState()
        var saved = signal("existing"); saved.acknowledged = true
        state.signals = [saved]
        for (apiState, draft, merged, expected) in [("open", false, false, "open"), ("open", true, false, "draft"), ("closed", false, true, "merged"), ("closed", true, false, "closed")] {
            var responses = subjectResponses(owner: "me", body: "", comments: "[]")
            var subject = try JSONSerialization.jsonObject(with: responses[0].data) as! [String: Any]
            subject["state"] = apiState; subject["draft"] = draft; subject["merged"] = merged
            responses[0] = APIResponse(data: try JSONSerialization.data(withJSONObject: subject))
            let batch = try await GitHubClient(transport: StubTransport(responses: responses)).details(for: PendingThread(thread: decodeThread(), since: now), login: "me")
            XCTAssertTrue(batch.signals.isEmpty)
            state.merge(batch)
            let restored = try JSONDecoder().decode(InboxState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(restored.pullRequests[saved.threadKey]?.status, expected)
            XCTAssertTrue(restored.signals[0].acknowledged)
            XCTAssertEqual(restored.signals.count, 1)
            state.merge(SignalBatch(signals: [], threadKey: saved.threadKey, pullRequest: PullRequestInfo(state: nil, draft: nil, merged: nil)))
            XCTAssertEqual(state.pullRequests[saved.threadKey]?.status, expected)
        }
    }

    func testPRStatusRefreshRejectsForeignAndIssueURLs() async throws {
        var value = signal("1")
        XCTAssertEqual(PullRequestInfo.apiPath(for: value), "/repos/org/repo/pulls/1")
        value.url = "https://github.com/pull/pull/pull/1/files"
        XCTAssertEqual(PullRequestInfo.apiPath(for: value), "/repos/pull/pull/pulls/1")
        for url in ["https://evil.test/org/repo/pull/1", "https://github.com/org/repo/issues/1", "https://github.com/org/repo/pull/not-a-number"] {
            value.url = url
            let transport = StubTransport(responses: [])
            do { _ = try await GitHubClient(transport: transport).pullRequest(for: value); XCTFail("Must reject") }
            catch { }
            let paths = await transport.paths
            XCTAssertTrue(paths.isEmpty)
        }
    }

    private func signal(_ id: String) -> Signal {
        Signal(id: id, kind: .mention, repository: "org/repo", title: "Title", actor: "other", excerpt: "@me", url: "https://github.com/org/repo/pull/1", date: now)
    }
    private var threadJSON: String {
        "{\"id\":\"1\",\"reason\":\"mention\",\"updated_at\":\"2026-09-17T12:00:00Z\",\"subject\":{\"title\":\"Title\",\"url\":\"https://api.github.com/repos/org/repo/pulls/1\",\"type\":\"PullRequest\"},\"repository\":{\"full_name\":\"org/repo\"}}"
    }
    private func decodeThread() throws -> NotificationThread { try JSONCoding.decoder().decode(NotificationThread.self, from: Data(threadJSON.utf8)) }
    private func subjectResponses(owner: String, body: String, comments: String) -> [APIResponse] {
        [APIResponse(data: Data("{\"title\":\"Title\",\"body\":\"\(body)\",\"user\":{\"login\":\"\(owner)\"},\"html_url\":\"https://github.com/org/repo/pull/1\",\"updated_at\":\"2026-09-17T12:00:00Z\"}".utf8)),
         APIResponse(data: Data(comments.utf8)),
         APIResponse(data: Data("[]".utf8)), APIResponse(data: Data("[]".utf8)), APIResponse(data: Data("[]".utf8))]
    }
}

private actor StubTransport: GitHubTransport {
    var responses: [APIResponse]
    private(set) var paths: [String] = []
    init(responses: [APIResponse]) { self.responses = responses }
    func get(_ path: String) async throws -> APIResponse {
        paths.append(path)
        guard !responses.isEmpty else { throw SignalError.message("Simulated connection failure") }
        return responses.removeFirst()
    }
}
