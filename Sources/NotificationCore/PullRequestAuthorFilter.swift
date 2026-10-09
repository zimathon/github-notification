import Foundation

public enum PullRequestAuthorFilter: String, CaseIterable {
    case all, mine, others

    public var title: String {
        switch self {
        case .all: return "作成者：すべて"
        case .mine: return "自分のPR"
        case .others: return "他者のPR"
        }
    }

    public func includes(_ signal: Signal, info: PullRequestInfo?, account: String?) -> Bool {
        guard self != .all else { return true }
        guard PullRequestInfo.apiPath(for: signal) != nil,
              let author = info?.author, !author.isEmpty,
              let account, !account.isEmpty else { return false }
        let own = author.caseInsensitiveCompare(account) == .orderedSame
        return self == .mine ? own : !own
    }
}
