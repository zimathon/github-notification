import Foundation

public enum ReviewBot: String, CaseIterable, Identifiable {
    case codex, claude
    public var id: String { rawValue }
    public var title: String { self == .codex ? "Codex" : "Claude" }
    public var comment: String {
        switch self {
        case .codex: return "@codex review"
        case .claude: return "@claude このPRをレビューしてください。コードの変更やcommit・pushは行わず、指摘をコメントしてください。"
        }
    }
}

public struct BotReviewRequest: Identifiable, Equatable {
    public let path: String
    public let url: URL
    public let title: String
    public let bot: ReviewBot
    public var id: String { path + ":" + bot.rawValue }
    public var body: String { bot.comment }

    public init?(signal: Signal, bot: ReviewBot) {
        guard let apiPath = PullRequestInfo.apiPath(for: signal) else { return nil }
        let parts = apiPath.split(separator: "/")
        path = "/repos/\(parts[1])/\(parts[2])/issues/\(parts[4])/comments"
        guard Self.isCommentPath(path),
              let url = URL(string: "https://github.com/\(parts[1])/\(parts[2])/pull/\(parts[4])") else { return nil }
        self.url = url; title = signal.title; self.bot = bot
    }

    public static func isCommentPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard !parts.contains("."), !parts.contains("..") else { return false }
        return path.range(of: #"\A/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+/comments\z"#,
                   options: .regularExpression) != nil && !path.contains("\n") && !path.contains("\r")
    }

    public static func plan(signals: [Signal], bots: Set<ReviewBot>) -> [BotReviewRequest] {
        var seen = Set<String>()
        return signals.flatMap { signal in
            ReviewBot.allCases.filter { bots.contains($0) }.compactMap { bot in
                guard let request = BotReviewRequest(signal: signal, bot: bot), seen.insert(request.id).inserted else { return nil }
                return request
            }
        }
    }
}

public enum BotReviewError: Error {
    case accountMismatch, accountVerificationFailed
}

public protocol ReviewCommentTransport: GitHubTransport {
    func postComment(_ path: String, body: String) async throws -> APIResponse
}

public struct BotReviewClient {
    private let transport: any ReviewCommentTransport
    public init(transport: any ReviewCommentTransport) { self.transport = transport }
    // A write is attempted exactly once. A timeout may still mean GitHub accepted it.
    public func send(_ request: BotReviewRequest, account: String) async throws {
        guard !account.isEmpty else { throw BotReviewError.accountMismatch }
        let login: String
        do {
            let response = try await transport.get("/user")
            login = try JSONDecoder().decode(GitHubUser.self, from: response.data).login
        } catch { throw BotReviewError.accountVerificationFailed }
        guard login.caseInsensitiveCompare(account) == .orderedSame else { throw BotReviewError.accountMismatch }
        _ = try await transport.postComment(request.path, body: request.body)
    }
}
