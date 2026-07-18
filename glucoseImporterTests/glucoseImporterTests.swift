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

@MainActor
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

// MARK: - CSVStructureDetector 테스트 (나라별 CSV 구조)

@MainActor
struct CSVStructureDetectorTests {

    // 미국식: 콤마 구분자
    @Test func detectsCommaDelimiter() {
        let lines = ["date,glucose", "03/05/2024,120", "03/06/2024,130"]
        #expect(CSVStructureDetector.detectDelimiter(lines: lines) == ",")
    }

    // 유럽식: 세미콜론 구분자 + 소수점 콤마가 섞여 있어도 세미콜론을 골라야 한다
    @Test func detectsSemicolonDelimiterWithDecimalComma() {
        let lines = ["Datum;Glukose", "25.03.2024 08:05;120,5", "26.03.2024 09:10;98,3"]
        #expect(CSVStructureDetector.detectDelimiter(lines: lines) == ";")
    }

    // 탭 구분자
    @Test func detectsTabDelimiter() {
        let lines = ["date\tglucose", "2024-03-05\t120", "2024-03-06\t130"]
        #expect(CSVStructureDetector.detectDelimiter(lines: lines) == "\t")
    }

    // 판단 근거가 없으면 콤마로 폴백
    @Test func fallsBackToComma() {
        #expect(CSVStructureDetector.detectDelimiter(lines: []) == ",")
    }

    // 표준 소수점
    @Test func parsesStandardDecimal() {
        #expect(CSVStructureDetector.parseDecimal("120.5") == 120.5)
        #expect(CSVStructureDetector.parseDecimal("120") == 120)
        #expect(CSVStructureDetector.parseDecimal(" 98 ") == 98)
    }

    // 유럽식 소수점 콤마
    @Test func parsesEuropeanDecimalComma() {
        #expect(CSVStructureDetector.parseDecimal("120,5") == 120.5)
        #expect(CSVStructureDetector.parseDecimal("5,6") == 5.6)
    }

    // 유럽식 천단위 점 + 소수점 콤마
    @Test func parsesEuropeanThousandsSeparator() {
        #expect(CSVStructureDetector.parseDecimal("1.234,5") == 1234.5)
    }

    // 숫자가 아니면 nil
    @Test func rejectsNonNumeric() {
        #expect(CSVStructureDetector.parseDecimal("") == nil)
        #expect(CSVStructureDetector.parseDecimal("abc") == nil)
    }
}

// MARK: - 실제 파일 통합 테스트 (전체 파이프라인)

@MainActor
struct GlucoseCSVReaderIntegrationTests {

    /// 임시 CSV 파일을 만들어 리더에 통과시킨다.
    private func withTempCSV(_ contents: String, _ body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).csv")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    /// 유럽식 CSV(세미콜론 구분자 + 소수점 콤마 + dd.MM.yyyy)가 통째로 파싱되는지.
    /// 이전에는 구분자·소수점 때문에 전량 실패하던 케이스.
    @Test func importsEuropeanStyleCSV() async throws {
        let csv = """
        Datum;Glukose
        25.03.2024 08:05;120,5
        26.03.2024 09:10;98,3
        """
        try await withTempCSV(csv) { url in
            let result = try await GlucoseCSVReader().read(
                from: url,
                targetUnit: .mgDL,
                manualConfig: ManualCSVFormat(dateColumnIndex: 0, valueColumnIndex: 1)
            )
            #expect(result.detectedDelimiter == ";")
            #expect(result.validRecords.count == 2)
            #expect(result.validRecords.first?.value == 120.5)
            // 25일은 12를 넘으므로 일-먼저로 확정되어야 한다
            #expect(result.usedDateOrder == .dayFirst)
        }
    }

    /// 미국식 CSV(콤마 구분자 + MM/dd/yyyy)가 정상 파싱되는지.
    @Test func importsUSStyleCSV() async throws {
        let csv = """
        date,glucose
        03/25/2024 08:05,120
        03/26/2024 09:10,98
        """
        try await withTempCSV(csv) { url in
            let result = try await GlucoseCSVReader().read(
                from: url,
                targetUnit: .mgDL,
                manualConfig: ManualCSVFormat(dateColumnIndex: 0, valueColumnIndex: 1)
            )
            #expect(result.detectedDelimiter == ",")
            #expect(result.validRecords.count == 2)
            // 둘째 자리가 25 → 월-먼저로 확정
            #expect(result.usedDateOrder == .monthFirst)
        }
    }

    /// 사용자가 미리보기에서 일/월 순서를 뒤집으면 그 지정이 실제로 반영되는지.
    /// (전부 12 이하라 자동으로는 판단 불가능한 파일)
    @Test func honorsUserDateOrderOverride() async throws {
        let csv = """
        date,glucose
        03/05/2024 08:05,120
        04/06/2024 09:10,98
        """
        try await withTempCSV(csv) { url in
            let config = ManualCSVFormat(dateColumnIndex: 0, valueColumnIndex: 1)
            let cal = Calendar(identifier: .gregorian)

            let dayFirst = try await GlucoseCSVReader().read(
                from: url, targetUnit: .mgDL, manualConfig: config, dateOrderOverride: .dayFirst
            )
            let monthFirst = try await GlucoseCSVReader().read(
                from: url, targetUnit: .mgDL, manualConfig: config, dateOrderOverride: .monthFirst
            )

            let dayFirstMonth = cal.component(.month, from: dayFirst.validRecords[0].timestamp)
            let monthFirstMonth = cal.component(.month, from: monthFirst.validRecords[0].timestamp)

            #expect(dayFirstMonth == 5)    // 03/05 → 5월 3일
            #expect(monthFirstMonth == 3)  // 03/05 → 3월 5일
        }
    }
}
