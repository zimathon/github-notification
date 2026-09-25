import XCTest
@testable import NotificationCore

final class SignalDateRangeTests: XCTestCase {
    func testLocalCalendarBoundariesIncludingDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let format = ISO8601DateFormatter()
        let now = format.date(from: "2026-03-09T12:00:00-07:00")!
        for (range, start) in [(SignalDateRange.today, "2026-03-09T00:00:00-07:00"),
                               (.week, "2026-03-03T00:00:00-08:00"),
                               (.month, "2026-02-08T00:00:00-08:00")] {
            let boundary = format.date(from: start)!
            XCTAssertTrue(range.includes(boundary, now: now, calendar: calendar))
            XCTAssertFalse(range.includes(boundary.addingTimeInterval(-1), now: now, calendar: calendar))
            XCTAssertTrue(range.includes(now, now: now, calendar: calendar))
            XCTAssertTrue(range.includes(now.addingTimeInterval(1), now: now, calendar: calendar))
        }
        XCTAssertFalse(SignalDateRange.today.includes(format.date(from: "2026-03-10T00:00:00-07:00")!, now: now, calendar: calendar))
        XCTAssertTrue(SignalDateRange.all.includes(.distantPast, now: now, calendar: calendar))
    }
}
