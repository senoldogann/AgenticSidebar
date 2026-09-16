import Foundation
import XCTest
@testable import AgenticSidebar

final class SessionListQueryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12))!
    }

    private func makeSummary(
        title: String,
        createdAt: Date,
        lastMessageAt: Date? = nil,
        completedAt: Date? = nil,
        customTitle: String? = nil,
        isPinned: Bool = false
    ) -> SessionSummary {
        SessionSummary(
            id: UUID(),
            title: title,
            isBusy: false,
            status: .idle,
            completedAt: completedAt,
            lastMessageAt: lastMessageAt,
            createdAt: createdAt,
            customTitle: customTitle,
            isPinned: isPinned
        )
    }

    func testSearchIsCaseInsensitive() {
        let first = makeSummary(title: "Build Failure", createdAt: now)
        let second = makeSummary(title: "deploy notes", createdAt: now)
        let result = filterSortSessions(
            [first, second],
            query: "build",
            sort: .lastUsedNewest,
            dateFilter: .all,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result.map(\.id), [first.id])
    }

    func testSearchMatchesCustomTitle() {
        let renamed = makeSummary(title: "hello", createdAt: now, customTitle: "Ödeme akışı")
        let result = filterSortSessions(
            [renamed],
            query: "ödeme",
            sort: .lastUsedNewest,
            dateFilter: .all,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result.count, 1)
    }

    func testAlphabeticalSortOrdersByDisplayTitle() {
        let beta = makeSummary(title: "beta", createdAt: now)
        let alpha = makeSummary(title: "alpha", createdAt: now)
        let result = filterSortSessions(
            [beta, alpha],
            query: "",
            sort: .alphabetical,
            dateFilter: .all,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result.map(\.title), ["alpha", "beta"])
    }

    func testCreatedSortNewestAndOldest() {
        let old = makeSummary(title: "old", createdAt: now.addingTimeInterval(-100))
        let new = makeSummary(title: "new", createdAt: now)
        let newestFirst = filterSortSessions(
            [old, new],
            query: "",
            sort: .createdNewest,
            dateFilter: .all,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(newestFirst.map(\.title), ["new", "old"])
        let oldestFirst = filterSortSessions(
            [old, new],
            query: "",
            sort: .createdOldest,
            dateFilter: .all,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(oldestFirst.map(\.title), ["old", "new"])
    }

    func testLastUsedSortUsesLastMessageFallback() {
        let recent = makeSummary(
            title: "recent",
            createdAt: now.addingTimeInterval(-1000),
            lastMessageAt: now.addingTimeInterval(-10)
        )
        let older = makeSummary(
            title: "older",
            createdAt: now,
            lastMessageAt: now.addingTimeInterval(-1000)
        )
        let result = filterSortSessions(
            [older, recent],
            query: "",
            sort: .lastUsedNewest,
            dateFilter: .all,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result.map(\.title), ["recent", "older"])
    }

    func testPinnedSessionsStayOnTop() {
        let plain = makeSummary(title: "aaa plain", createdAt: now)
        let pinned = makeSummary(title: "zzz pinned", createdAt: now.addingTimeInterval(-100), isPinned: true)
        let result = filterSortSessions(
            [plain, pinned],
            query: "",
            sort: .alphabetical,
            dateFilter: .all,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result.map(\.id), [pinned.id, plain.id])
    }

    func testDateFilters() {
        let today = makeSummary(title: "today", createdAt: now, lastMessageAt: now)
        let week = makeSummary(
            title: "week",
            createdAt: now.addingTimeInterval(-3 * 24 * 3600),
            lastMessageAt: now.addingTimeInterval(-3 * 24 * 3600)
        )
        let old = makeSummary(
            title: "old",
            createdAt: now.addingTimeInterval(-60 * 24 * 3600),
            lastMessageAt: now.addingTimeInterval(-60 * 24 * 3600)
        )
        let all = [today, week, old]

        let todayOnly = filterSortSessions(all, query: "", sort: .lastUsedNewest, dateFilter: .today, now: now, calendar: calendar)
        XCTAssertEqual(todayOnly.map(\.title), ["today"])

        let last7 = filterSortSessions(all, query: "", sort: .lastUsedNewest, dateFilter: .last7Days, now: now, calendar: calendar)
        XCTAssertEqual(Set(last7.map(\.title)), ["today", "week"])

        let last30 = filterSortSessions(all, query: "", sort: .lastUsedNewest, dateFilter: .last30Days, now: now, calendar: calendar)
        XCTAssertEqual(Set(last30.map(\.title)), ["today", "week"])

        let older = filterSortSessions(all, query: "", sort: .lastUsedNewest, dateFilter: .older, now: now, calendar: calendar)
        XCTAssertEqual(older.map(\.title), ["old"])
    }

    func testEmptyListReturnsEmpty() {
        let result = filterSortSessions([], query: "x", sort: .alphabetical, dateFilter: .today, now: now, calendar: calendar)
        XCTAssertTrue(result.isEmpty)
    }
}
