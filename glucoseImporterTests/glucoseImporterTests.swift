//
//  glucoseImporterTests.swift
//  glucoseImporterTests
//
//  Created by 오승준 on 2/20/26.
//

import Testing
import Foundation
@testable import glucoseImporter

struct glucoseImporterTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }
}

// MARK: - FlexibleDateParser 테스트

struct FlexibleDateParserTests {

    /// 지정한 연/월/일을 현재 타임존 기준으로 만든다 (파싱 결과 비교용).
    private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal.date(from: comps)!
    }

    // 연도-먼저 포맷은 순서와 무관하게 항상 파싱된다
    @Test func parsesISOAndYearFirstFormats() {
        #expect(FlexibleDateParser.parse("2024-03-05T14:30:00", order: .monthFirst)?.date == makeDate(2024, 3, 5, 14, 30))
        #expect(FlexibleDateParser.parse("2024-03-05 14:30:00", order: .dayFirst)?.date == makeDate(2024, 3, 5, 14, 30))
        #expect(FlexibleDateParser.parse("2024-03-05", order: .dayFirst)?.date == makeDate(2024, 3, 5))
        // 한국식 yyyy-mm-dd
        #expect(FlexibleDateParser.parse("2024-11-25 08:05", order: .monthFirst)?.date == makeDate(2024, 11, 25, 8, 5))
        // yyyy.MM.dd
        #expect(FlexibleDateParser.parse("2024.03.05 14:30", order: .dayFirst)?.date == makeDate(2024, 3, 5, 14, 30))
    }

    // 같은 문자열이 order에 따라 다르게 해석된다 (모호성의 핵심)
    @Test func ambiguousDateRespectsOrder() {
        let usa = FlexibleDateParser.parse("03/05/2024 14:30", order: .monthFirst)
        #expect(usa?.date == makeDate(2024, 3, 5, 14, 30)) // 3월 5일

        let eu = FlexibleDateParser.parse("03/05/2024 14:30", order: .dayFirst)
        #expect(eu?.date == makeDate(2024, 5, 3, 14, 30))  // 5월 3일
    }

    // 유럽식 dd.MM.yyyy 및 dd/MM/yyyy
    @Test func parsesEuropeanFormats() {
        #expect(FlexibleDateParser.parse("25.03.2024 08:05", order: .dayFirst)?.date == makeDate(2024, 3, 25, 8, 5))
        #expect(FlexibleDateParser.parse("25/03/2024", order: .dayFirst)?.date == makeDate(2024, 3, 25))
    }

    // 2자리 연도가 4자리 포맷에 잘못 매칭돼 엉뚱한 연도가 나오는 것을 막는다
    @Test func rejectsImplausibleYear() {
        // "03/05/24" 가 yyyy/MM/dd 로 잘못 매칭되면 연도 3 → 걸러져야 한다
        let result = FlexibleDateParser.parse("03/05/24", order: .monthFirst)
        #expect(result == nil)
    }

    // 파일 전체 스캔으로 일-먼저(dd/MM) 자동 확정
    @Test func resolvesDayFirstFromColumn() {
        let lines = [
            "date,glucose",
            "03/05/2024,120",   // 모호
            "25/03/2024,130",   // 25 > 12 → dd/MM 확정
        ]
        #expect(FlexibleDateParser.resolveOrder(lines: lines, dateColumnIndex: 0) == .dayFirst)
    }

    // 파일 전체 스캔으로 월-먼저(MM/dd) 자동 확정
    @Test func resolvesMonthFirstFromColumn() {
        let lines = [
            "date,glucose",
            "03/05/2024,120",   // 모호
            "03/25/2024,130",   // 둘째가 25 > 12 → MM/dd 확정
        ]
        #expect(FlexibleDateParser.resolveOrder(lines: lines, dateColumnIndex: 0) == .monthFirst)
    }

    // 연도-먼저 컬럼은 판단 근거가 없어 Locale 기본값으로 폴백 (크래시 없이 값 반환)
    @Test func yearFirstColumnFallsBackToLocale() {
        let lines = ["date,glucose", "2024-03-05,120", "2024-11-25,130"]
        let order = FlexibleDateParser.resolveOrder(lines: lines, dateColumnIndex: 0)
        #expect(order == .dayFirst || order == .monthFirst)
    }
}
