import XCTest
@testable import watchCat

final class DateRangeTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar.current.date(from: c)!
    }

    // 2026-05-13 is a Wednesday. Week should span Mon 5/11 → Sun 5/17.
    func test_week_snapsToMondaySunday_fromWednesday() {
        let r = DashboardRange.week(containing: date(2026, 5, 13))
        XCTAssertEqual(DayKey.string(for: r.start), "2026-05-11")
        XCTAssertEqual(DayKey.string(for: r.end), "2026-05-17")
        XCTAssertEqual(r.dayCount, 7)
    }

    // 2026-05-11 (Monday) — week starts on itself.
    func test_week_anchoredOnMonday_isUnchanged() {
        let r = DashboardRange.week(containing: date(2026, 5, 11))
        XCTAssertEqual(DayKey.string(for: r.start), "2026-05-11")
        XCTAssertEqual(DayKey.string(for: r.end), "2026-05-17")
    }

    // 2026-05-17 (Sunday) — last day of the same week.
    func test_week_anchoredOnSunday_endsOnSelf() {
        let r = DashboardRange.week(containing: date(2026, 5, 17))
        XCTAssertEqual(DayKey.string(for: r.start), "2026-05-11")
        XCTAssertEqual(DayKey.string(for: r.end), "2026-05-17")
    }

    func test_month_spansFullCalendarMonth() {
        let r = DashboardRange.month(containing: date(2026, 5, 13))
        XCTAssertEqual(DayKey.string(for: r.start), "2026-05-01")
        XCTAssertEqual(DayKey.string(for: r.end), "2026-05-31")
        XCTAssertEqual(r.dayCount, 31)
    }

    // February (non-leap 2026): 28 days.
    func test_month_february2026_has28Days() {
        let r = DashboardRange.month(containing: date(2026, 2, 14))
        XCTAssertEqual(r.dayCount, 28)
        XCTAssertEqual(DayKey.string(for: r.end), "2026-02-28")
    }

    // Leap year February (2028): 29 days.
    func test_month_february2028_has29Days() {
        let r = DashboardRange.month(containing: date(2028, 2, 14))
        XCTAssertEqual(r.dayCount, 29)
        XCTAssertEqual(DayKey.string(for: r.end), "2028-02-29")
    }

    func test_day_isSingleDay() {
        let r = DashboardRange.day(date(2026, 5, 13))
        XCTAssertEqual(r.dayCount, 1)
        XCTAssertEqual(r.dayKeys.first, "2026-05-13")
        XCTAssertEqual(r.dayKeys.last, "2026-05-13")
    }

    func test_custom_swapsBackwardEndpoints() {
        let r = DashboardRange.custom(from: date(2026, 5, 20), to: date(2026, 5, 13))
        XCTAssertEqual(DayKey.string(for: r.start), "2026-05-13")
        XCTAssertEqual(DayKey.string(for: r.end), "2026-05-20")
        XCTAssertEqual(r.dayCount, 8)
    }

    func test_enumerateDayKeys_isContiguous() {
        let r = DashboardRange.custom(from: date(2026, 5, 13), to: date(2026, 5, 15))
        XCTAssertEqual(r.enumerateDayKeys(), ["2026-05-13", "2026-05-14", "2026-05-15"])
    }

    func test_shift_byWeek_advancesAcrossMonth() {
        let r = DashboardRange.week(containing: date(2026, 5, 28))
        // Week containing 5/28 is 5/25 (Mon) → 5/31 (Sun). Next week: 6/1 → 6/7.
        XCTAssertEqual(DayKey.string(for: r.start), "2026-05-25")
        let next = DashboardRange.shift(r, period: .week, by: 1)
        XCTAssertEqual(DayKey.string(for: next.start), "2026-06-01")
        XCTAssertEqual(DayKey.string(for: next.end), "2026-06-07")
    }

    func test_shift_byMonth_handlesShortMonths() {
        // Anchor in Jan → Feb → Mar to make sure dayCount changes correctly.
        let jan = DashboardRange.month(containing: date(2026, 1, 15))
        XCTAssertEqual(jan.dayCount, 31)
        let feb = DashboardRange.shift(jan, period: .month, by: 1)
        XCTAssertEqual(feb.dayCount, 28)
        XCTAssertEqual(DayKey.string(for: feb.start), "2026-02-01")
        XCTAssertEqual(DayKey.string(for: feb.end), "2026-02-28")
    }

    func test_shift_byRange_advancesBySpanDays() {
        let r = DashboardRange.custom(from: date(2026, 5, 1), to: date(2026, 5, 10))  // 10 days
        let next = DashboardRange.shift(r, period: .range, by: 1)
        XCTAssertEqual(DayKey.string(for: next.start), "2026-05-11")
        XCTAssertEqual(DayKey.string(for: next.end), "2026-05-20")
    }
}
