import Foundation

public enum SignalDateRange: Int, CaseIterable {
    case all = 0, today = 1, week = 7, month = 30

    public var title: String {
        switch self {
        case .all: return "全期間"
        case .today: return "今日"
        case .week: return "過去7日"
        case .month: return "過去30日"
        }
    }

    // Calendar days in the user's timezone, including today (not rolling 24-hour windows).
    public func includes(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard self != .all else { return true }
        let start = calendar.date(byAdding: .day, value: 1 - rawValue, to: calendar.startOfDay(for: now))!
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return date >= start && date < end
    }
}
