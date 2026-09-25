import Foundation
import CryptoKit

public struct APIResponse {
    public var data: Data
    public var headers: [String: String]
    public init(data: Data, headers: [String: String] = [:]) { self.data = data; self.headers = headers }
    public var serverDate: Date? {
        guard let value = headers["date"] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value)
    }
}

public protocol GitHubTransport {
    func get(_ path: String) async throws -> APIResponse
}

public struct NotificationBatch {
    public var threads: [NotificationThread]
    public var serverDate: Date
    public var pollInterval: TimeInterval
}

public struct GitHubClient {
    let transport: any GitHubTransport
    public init(transport: any GitHubTransport) { self.transport = transport }

    public func account() async throws -> (login: String, now: Date) {
        let response = try await transport.get("/user")
        let user = try JSONCoding.decoder().decode(GitHubUser.self, from: response.data)
        guard let now = response.serverDate else { throw SignalError.message("GitHubのサーバー時刻を取得できませんでした。") }
        return (user.login, now)
    }

    public func notifications(since: Date) async throws -> NotificationBatch {
        let date = ISO8601DateFormatter().string(from: since)
        let first = try await transport.get("/notifications?all=true&since=\(date)&per_page=100&page=1")
        let threads: [NotificationThread] = try await pages(first, path: "/notifications?all=true&since=\(date)&per_page=100")
        guard let serverDate = first.serverDate else { throw SignalError.message("GitHubのサーバー時刻を取得できませんでした。") }
        return NotificationBatch(threads: threads, serverDate: serverDate,
                                 pollInterval: max(60, Double(first.headers["x-poll-interval"] ?? "60") ?? 60))
    }

    private func list<T: Decodable>(_ path: String) async throws -> [T] {
        let path = path + (path.contains("?") ? "&" : "?") + "per_page=100"
        let first = try await transport.get(path + "&page=1")
        return try await pages(first, path: path)
    }

    private func pages<T: Decodable>(_ first: APIResponse, path: String) async throws -> [T] {
        var response = first
        var result: [T] = []
        for page in 1...100 {
            result += try JSONCoding.decoder().decode([T].self, from: response.data)
            guard response.headers["link"]?.contains("rel=\"next\"") == true else { return result }
            guard page < 100 else { throw SignalError.message("通知の取得件数が上限を超えたため、更新を完了できませんでした。") }
            response = try await transport.get(path + "&page=\(page + 1)")
        }
        return result
    }

    public func signals(for pending: PendingThread, login: String) async throws -> [Signal] {
        try await details(for: pending, login: login).signals
    }

    public func pullRequest(for signal: Signal) async throws -> PullRequestInfo {
        guard let path = PullRequestInfo.apiPath(for: signal) else { throw SignalError.message("PRのURLを確認できませんでした。") }
        let response = try await transport.get(path)
        let subject = try JSONCoding.decoder().decode(Subject.self, from: response.data)
        let info = PullRequestInfo(state: subject.state, draft: subject.draft, merged: subject.merged)
        guard info.status != nil else { throw SignalError.message("PRの状態を取得できませんでした。") }
        return info
    }

    public func details(for pending: PendingThread, login: String) async throws -> SignalBatch {
        let thread = pending.thread
        guard ["PullRequest", "Issue"].contains(thread.subject.type) else { return SignalBatch(signals: []) }
        guard let rawURL = thread.subject.url, let url = URL(string: rawURL),
              url.scheme == "https", url.host == "api.github.com", url.user == nil,
              url.password == nil, url.port == nil, url.query == nil,
              url.path.range(of: #"^/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pulls|issues)/[0-9]+$"#,
                             options: .regularExpression) != nil else {
            throw SignalError.message("通知のリンク先を確認できませんでした。")
        }
        let response = try await transport.get(url.path)
        let subject = try JSONCoding.decoder().decode(Subject.self, from: response.data)
        let isPR = thread.subject.type == "PullRequest"
        let ownPR = isPR && subject.user.login.caseInsensitiveCompare(login) == .orderedSame
        let issuePath = url.path.replacingOccurrences(of: "/pulls/", with: "/issues/")
        let since = ISO8601DateFormatter().string(from: pending.since)
        let comments: [Comment] = try await list(issuePath + "/comments?since=\(since)")
        var result: [Signal] = []

        func append(id: String, body: String, user: GitHubUser, date: Date, webURL: String,
                    review: Bool = false, kind forcedKind: SignalKind? = nil) {
            guard date >= pending.since, user.login.caseInsensitiveCompare(login) != .orderedSame else { return }
            // Keep the rule independent of settings so disabling notifications does not lose events.
            guard let kind = forcedKind ?? SignalRules.kind(body: body, actor: user.login, login: login,
                                                           ownPR: ownPR, isReview: review) else { return }
            guard SignalRules.safeWebURL(webURL) != nil else { return }
            let actor = user.type == "Bot" && !user.login.hasSuffix("[bot]") ? user.login + "[bot]" : user.login
            result.append(Signal(id: id, kind: kind, repository: thread.repository.fullName,
                                 title: subject.title, actor: actor, excerpt: body, url: webURL, date: date))
        }

        if SignalRules.mentions(subject.body ?? "", login: login) {
            let digest = SHA256.hash(data: Data((subject.body ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
            append(id: "body:\(thread.id):\(digest)", body: subject.body ?? "",
                   user: subject.user, date: subject.updatedAt, webURL: subject.htmlUrl, kind: .mention)
        }
        for comment in comments {
            append(id: "comment:\(comment.id):\(comment.updatedAt.timeIntervalSince1970)", body: comment.body ?? "",
                   user: comment.user, date: comment.updatedAt, webURL: comment.htmlUrl)
        }
        if isPR {
            let inline: [Comment] = try await list(url.path + "/comments?since=\(since)")
            for comment in inline {
                append(id: "inline:\(comment.id):\(comment.updatedAt.timeIntervalSince1970)", body: comment.body ?? "",
                       user: comment.user, date: comment.updatedAt, webURL: comment.htmlUrl)
            }
            let reviews: [Review] = try await list(url.path + "/reviews")
            for review in reviews where review.state != "PENDING" {
                guard let date = review.submittedAt, let user = review.user else { continue }
                let body = [review.label, review.body ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
                append(id: "review:\(review.id):\(review.state)", body: body,
                       user: user, date: date, webURL: review.htmlUrl, review: true)
            }
            // The event ID also distinguishes repeated requests between two polling runs.
            // Issue events include review requests without the timeline's full comment/commit bodies.
            let events: [TimelineEvent] = try await list(issuePath + "/events")
            for event in events where event.event == "review_requested" {
                guard event.requestedReviewer?.login.caseInsensitiveCompare(login) == .orderedSame,
                      let actor = event.actor, let id = event.id, let date = event.createdAt else { continue }
                append(id: "request:\(id)", body: "あなたへのレビュー依頼", user: actor,
                       date: date, webURL: subject.htmlUrl, kind: .reviewRequest)
            }
        }
        let key = Signal(id: "", kind: .review, repository: thread.repository.fullName, title: "", actor: "", excerpt: "", url: subject.htmlUrl, date: Date()).threadKey
        return SignalBatch(signals: result, threadKey: key, pullRequest: isPR ? PullRequestInfo(state: subject.state, draft: subject.draft, merged: subject.merged) : nil)
    }
}

private struct Subject: Decodable {
    var title: String; var body: String?; var user: GitHubUser
    var htmlUrl: String; var updatedAt: Date
    var state: String?; var draft: Bool?; var merged: Bool?
}
private struct Comment: Decodable {
    var id: Int64; var body: String?; var user: GitHubUser
    var htmlUrl: String; var updatedAt: Date
}
private struct Review: Decodable {
    var id: Int64; var body: String?; var user: GitHubUser?
    var state: String; var submittedAt: Date?; var htmlUrl: String
    var label: String {
        switch state {
        case "APPROVED": return "承認"
        case "CHANGES_REQUESTED": return "変更リクエスト"
        case "DISMISSED": return "レビューの取り消し"
        default: return "レビューコメント"
        }
    }
}
private struct TimelineEvent: Decodable {
    var id: Int64?; var event: String?; var actor: GitHubUser?
    var requestedReviewer: GitHubUser?; var createdAt: Date?
}
