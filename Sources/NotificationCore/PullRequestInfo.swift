import Foundation

public struct PullRequestInfo: Codable, Equatable {
    public var status: String?
    public var checkedAt: Date

    public init(state: String?, draft: Bool?, merged: Bool?, checkedAt: Date = Date()) {
        status = merged == true ? "merged" : state == "closed" ? "closed" : state == "open" ? (draft == true ? "draft" : "open") : nil
        self.checkedAt = checkedAt
    }

    public var label: String {
        switch status {
        case "open": return "🟢 Open"
        case "draft": return "⚪ Draft"
        case "merged": return "🟣 マージ済み"
        case "closed": return "🔴 クローズ"
        default: return "状態未取得"
        }
    }

    public static func apiPath(for signal: Signal) -> String? {
        guard let url = SignalRules.safeWebURL(signal.url), url.host == "github.com",
              let match = url.path.range(of: #"^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+(?=/|$)"#, options: .regularExpression) else { return nil }
        let parts = url.path[match].split(separator: "/")
        return "/repos/\(parts[0])/\(parts[1])/pulls/\(parts[3])"
    }
}

public struct SignalBatch {
    public var signals: [Signal]
    public var threadKey: String?
    public var pullRequest: PullRequestInfo?
}
