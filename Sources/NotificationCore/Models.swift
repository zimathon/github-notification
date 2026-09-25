import Foundation

public enum SignalKind: String, Codable, CaseIterable {
    case mention, reviewRequest, comment, review

    public var title: String {
        switch self {
        case .mention: return "メンション"
        case .reviewRequest: return "レビュー依頼"
        case .comment: return "自分のPRへのコメント"
        case .review: return "自分のPRへのレビュー"
        }
    }
}

public struct Signal: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: SignalKind
    public var repository: String
    public var title: String
    public var actor: String
    public var excerpt: String
    public var url: String
    public var date: Date
    public var acknowledged = false
    public var snoozedUntil: Date?
    public var lastNotifiedAt: Date?

    // Review IDs already retain GitHub's state, including in previously saved inboxes.
    public var reviewState: String? {
        guard id.range(of: #"^review:[0-9]+:[A-Z_]+$"#, options: .regularExpression) != nil else { return nil }
        return id.split(separator: ":").last.map(String.init)
    }

    public var isApproval: Bool { reviewState == "APPROVED" }

    public var kindLabel: String {
        switch reviewState {
        case "APPROVED": return "✅ 承認"
        case "CHANGES_REQUESTED": return "✏️ 修正依頼"
        case "DISMISSED": return "↩️ レビュー取消"
        default:
            switch kind {
            case .mention: return "📣 メンション"
            case .reviewRequest: return "👀 レビュー依頼"
            case .comment: return "💬 コメント"
            case .review: return "📝 レビュー"
            }
        }
    }

    public var threadKey: String {
        guard var components = URLComponents(string: url) else { return repository + ":" + url }
        let parts = components.path.split(separator: "/")
        if parts.count >= 4, ["pull", "issues"].contains(String(parts[2])), Int(parts[3]) != nil {
            components.path = "/" + parts.prefix(4).joined(separator: "/")
        }
        components.fragment = nil
        components.query = nil
        return repository.lowercased() + ":" + (components.string ?? url)
    }

    public init(id: String, kind: SignalKind, repository: String, title: String,
                actor: String, excerpt: String, url: String, date: Date) {
        self.id = id; self.kind = kind; self.repository = repository
        self.title = title; self.actor = actor; self.excerpt = String(excerpt.prefix(500))
        self.url = url; self.date = date
    }

    public func needsNotification(at now: Date, reminderMinutes: Int) -> Bool {
        guard !acknowledged, snoozedUntil.map({ $0 <= now }) ?? true else { return false }
        guard let lastNotifiedAt else { return true }
        return reminderMinutes > 0 && now.timeIntervalSince(lastNotifiedAt) >= Double(reminderMinutes * 60)
    }
}

public struct Settings: Codable {
    public var mentions = true
    public var reviewRequests = true
    public var ownPRComments = true
    public var ownPRReviews = true
    public var includeBots = true
    public var reminderMinutes = 30
    public var pollSeconds = 120
    public var organizations: [String] = []
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case mentions, reviewRequests, ownPRComments, ownPRReviews, includeBots, reminderMinutes, pollSeconds, organizations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mentions = try values.decode(Bool.self, forKey: .mentions)
        reviewRequests = try values.decode(Bool.self, forKey: .reviewRequests)
        ownPRComments = try values.decode(Bool.self, forKey: .ownPRComments)
        ownPRReviews = try values.decode(Bool.self, forKey: .ownPRReviews)
        includeBots = try values.decode(Bool.self, forKey: .includeBots)
        reminderMinutes = try values.decode(Int.self, forKey: .reminderMinutes)
        pollSeconds = try values.decode(Int.self, forKey: .pollSeconds)
        organizations = try values.decodeIfPresent([String].self, forKey: .organizations) ?? []
    }

    public func includes(repository: String) -> Bool {
        guard !organizations.isEmpty else { return true }
        let owner = repository.split(separator: "/").first.map(String.init) ?? ""
        return organizations.contains { $0.caseInsensitiveCompare(owner) == .orderedSame }
    }

    public static func parseOrganizations(_ input: String) throws -> [String] {
        let names = input.components(separatedBy: CharacterSet(charactersIn: ",、 \n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard names.allSatisfy({ $0.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil }) else {
            throw SignalError.message("組織名またはユーザー名をカンマ区切りで入力してください。URLやリポジトリ名は不要です。")
        }
        return Array(Set(names)).sorted()
    }

    public func allows(_ kind: SignalKind) -> Bool {
        switch kind {
        case .mention: return mentions
        case .reviewRequest: return reviewRequests
        case .comment: return ownPRComments
        case .review: return ownPRReviews
        }
    }
}

public struct GitHubUser: Codable {
    public var login: String
    public var type: String?
    public init(login: String, type: String? = nil) { self.login = login; self.type = type }
}

public struct NotificationThread: Codable, Identifiable {
    public struct Subject: Codable {
        public var title: String
        public var url: String?
        public var type: String
    }
    public struct Repository: Codable { public var fullName: String }
    public var id: String
    public var reason: String
    public var updatedAt: Date
    public var subject: Subject
    public var repository: Repository
}

public struct PendingThread: Codable {
    public var thread: NotificationThread
    public var since: Date
}

public struct InboxState: Codable {
    public var enabled = false
    public var account: String?
    public var cursor: Date?
    public var signals: [Signal] = []
    public var pending: [String: PendingThread] = [:]
    public var processed: [String: Date] = [:]
    public var acknowledgedBodyIDs: Set<String> = []
    public var settings = Settings()
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, account, cursor, signals, pending, processed, acknowledgedBodyIDs, settings
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        account = try values.decodeIfPresent(String.self, forKey: .account)
        cursor = try values.decodeIfPresent(Date.self, forKey: .cursor)
        signals = try values.decode([Signal].self, forKey: .signals)
        pending = try values.decode([String: PendingThread].self, forKey: .pending)
        processed = try values.decode([String: Date].self, forKey: .processed)
        acknowledgedBodyIDs = try values.decodeIfPresent(Set<String>.self, forKey: .acknowledgedBodyIDs) ?? []
        settings = try values.decode(Settings.self, forKey: .settings)
    }

    /// Acknowledge only after the browser accepts the URL. Group rows cover the entire PR.
    public mutating func openSignal(_ id: String, entireThread: Bool, using opener: (URL) -> Bool) -> [String] {
        guard let signal = signals.first(where: { $0.id == id }),
              let url = SignalRules.safeWebURL(signal.url), opener(url) else { return [] }
        var acknowledged: [String] = []
        for index in signals.indices where entireThread ? signals[index].threadKey == signal.threadKey : signals[index].id == id {
            if !signals[index].acknowledged {
                signals[index].acknowledged = true
                acknowledged.append(signals[index].id)
            }
        }
        return acknowledged
    }

    public mutating func merge(_ incoming: [Signal]) {
        var known = Set(signals.map(\.id))
        for signal in incoming where !acknowledgedBodyIDs.contains(signal.id) && known.insert(signal.id).inserted { signals.append(signal) }
        signals.sort { $0.date > $1.date }
    }

    public mutating func enqueue(_ threads: [NotificationThread], since: Date, cursor: Date) {
        for thread in threads {
            guard processed[thread.id].map({ $0 < thread.updatedAt }) ?? true else { continue }
            pending[thread.id] = PendingThread(thread: thread, since: min(pending[thread.id]?.since ?? since, since))
        }
        self.cursor = cursor
    }

    public mutating func prune(before cutoff: Date) {
        for signal in signals where signal.acknowledged && signal.id.hasPrefix("body:") {
            acknowledgedBodyIDs.insert(signal.id)
        }
        signals.removeAll { $0.acknowledged && $0.date < cutoff }
        processed = processed.filter { $0.value >= cutoff }
    }
}

public enum SignalRules {
    public static func mentions(_ body: String, login: String) -> Bool {
        let pattern = "(?i)(?<![A-Za-z0-9_@/])@" + NSRegularExpression.escapedPattern(for: login) + "(?![A-Za-z0-9_/-])"
        return body.range(of: pattern, options: .regularExpression) != nil
    }

    public static func kind(body: String, actor: String, login: String, ownPR: Bool, isReview: Bool) -> SignalKind? {
        guard actor.caseInsensitiveCompare(login) != .orderedSame else { return nil }
        if mentions(body, login: login) { return .mention }
        if ownPR { return isReview ? .review : .comment }
        return nil
    }

    public static func safeWebURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        return url
    }
}

public enum SignalError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

public enum JSONCoding {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
