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

// MARK: - 하이픈 구분 날짜 (dd-MM-yyyy)

/// DateFormatter는 구분자(/ - .)를 호환되게 처리하므로 하이픈 날짜도
/// 슬래시 포맷으로 매칭된다. 내부 포맷 이름이 아니라 "값"이 맞는지를 검증한다.
@MainActor
struct HyphenDateTests {
    private func ymdhms(_ s: String, _ order: DateComponentOrder) -> String {
        guard let r = FlexibleDateParser.parse(s, order: order) else { return "nil" }
        let c = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.date)
        return "\(c.year!)-\(c.month!)-\(c.day!) \(c.hour!):\(c.minute!):\(c.second!)"
    }

    @Test func hyphenDayFirst() {
        #expect(ymdhms("25-03-2024", .dayFirst) == "2024-3-25 0:0:0")
        #expect(ymdhms("25-03-2024 08:05", .dayFirst) == "2024-3-25 8:5:0")
        #expect(ymdhms("25-03-2024 08:05:30", .dayFirst) == "2024-3-25 8:5:30")
    }

    // 한 자리 일/월도 허용 (5-3-2024)
    @Test func hyphenSingleDigit() {
        #expect(ymdhms("5-3-2024", .dayFirst) == "2024-3-5 0:0:0")
    }

    @Test func hyphenMonthFirst() {
        #expect(ymdhms("03-25-2024", .monthFirst) == "2024-3-25 0:0:0")
        #expect(ymdhms("03-25-2024 08:05:30", .monthFirst) == "2024-3-25 8:5:30")
    }

    // 같은 하이픈이라도 연도-먼저(한국식)는 순서 설정과 무관하게 유지돼야 한다.
    // dd-MM-yyyy 지원 때문에 yyyy-MM-dd가 깨지면 치명적이므로 반드시 검증.
    @Test func yearFirstStaysYearFirst() {
        #expect(ymdhms("2024-03-05", .dayFirst) == "2024-3-5 0:0:0")
        #expect(ymdhms("2024-03-05", .monthFirst) == "2024-3-5 0:0:0")
        #expect(ymdhms("2024-03-05 08:05", .dayFirst) == "2024-3-5 8:5:0")
    }

    // 파일 스캔이 하이픈 날짜에서도 일/월 순서를 판별하는지
    @Test func resolvesOrderFromHyphenDates() {
        let lines = ["date,glucose", "03-05-2024,120", "25-03-2024,130"]
        #expect(FlexibleDateParser.resolveOrder(lines: lines, dateColumnIndex: 0) == .dayFirst)
    }
}

// MARK: - 실제 Libre 파일 (하이픈 날짜) 재현

@MainActor
struct LibreHyphenDateTests {
    @Test func importsLibreWithHyphenDates() async throws {
        let csv = """
        FreeStyle LibreLink,E0E84C13-9B32-40D2-8E43-D24BF0686B9E,20-02-2026 22:34,0,136,,,,,,,,,,,,,,
        FreeStyle LibreLink,E0E84C13-9B32-40D2-8E43-D24BF0686B9E,20-02-2026 22:50,0,119,,,,,,,,,,,,,,
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("libre_\(UUID().uuidString).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await GlucoseCSVReader().read(from: url, targetUnit: .mgDL)

        #expect(result.validRecords.count == 2)
        if let first = result.validRecords.first {
            let c = Calendar(identifier: .gregorian)
                .dateComponents([.year, .month, .day, .hour, .minute], from: first.timestamp)
            // 20-02-2026 → 2026년 2월 20일 22:34
            #expect(c.year == 2026 && c.month == 2 && c.day == 20)
            #expect(c.hour == 22 && c.minute == 34)
            #expect(first.value == 136)
        }
    }
}

// MARK: - 실제 FreeStyle LibreLink 파일 (회귀 테스트)

@MainActor
struct RealLibreFileTests {

    /// 실제 LibreLink 내보내기 파일. 날짜가 dd-MM-yyyy(하이픈)이고
    /// 날짜는 2번 열에 있다. 일/월 순서 판별이 0번 열(기기명)을 보면
    /// 근거를 못 찾아 기기 지역으로 잘못 폴백되어 전량 파싱 실패했었다.
    @Test func importsRealLibreLinkFile() async throws {
        let csv = """
        혈당 데이터,생성일,2026-07-18 13:27 UTC,생성자,승준 오
        장치,일련 번호,장치 타임스탬프,기록 유형,과거 혈당 mg/dL,혈당 스캔 mg/dL,비수치적 초속효성 인슐린,초속효성 인슐린(단위),비수치적 식품,탄수화물(그램),탄수화물(1회 제공량),비수치적 지속형 인슐린,지속형 인슐린(단위),메모,스트립 혈당 mg/dL,케톤 mmol/L,식사 인슐린(단위),인슐린 수정(단위),사용자 변경 인슐린(단위)
        FreeStyle LibreLink,E0E84C13-9B32-40D2-8E43-D24BF0686B9E,20-02-2026 22:34,0,136,,,,,,,,,,,,,,
        FreeStyle LibreLink,E0E84C13-9B32-40D2-8E43-D24BF0686B9E,20-02-2026 22:50,0,119,,,,,,,,,,,,,,
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("libre_\(UUID().uuidString).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try await GlucoseCSVReader().read(from: url, targetUnit: .mgDL)

        #expect(r.vendor == .libre)
        #expect(r.validRecords.count == 2)
        #expect(r.invalidRecords.isEmpty)
        // 20-02-2026 은 일=20 이므로 일-먼저로 확정되어야 한다
        #expect(r.usedDateOrder == .dayFirst)

        let cal = Calendar(identifier: .gregorian)
        let first = cal.dateComponents([.year, .month, .day, .hour, .minute], from: r.validRecords[0].timestamp)
        #expect(first.year == 2026 && first.month == 2 && first.day == 20)
        #expect(first.hour == 22 && first.minute == 34)
        #expect(r.validRecords[0].value == 136)
        #expect(r.validRecords[1].value == 119)
    }
}

// MARK: - 조용히 버려지는 행 방지 (회귀 테스트)

@MainActor
struct SilentDropTests {

    private func makeCSV(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop_\(UUID().uuidString).csv")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 데이터 행이 파일 앞부분(5줄 이내)에 있고 날짜가 깨져도
    /// 헤더로 간주해 사라지지 않고 반드시 오류로 보고되어야 한다.
    @Test func libreDataRowFailureIsReportedNotSwallowed() async throws {
        let csv = """
        혈당 데이터,생성일,2026-07-18 13:27 UTC,생성자,승준 오
        장치,일련 번호,장치 타임스탬프,기록 유형,과거 혈당 mg/dL,혈당 스캔 mg/dL
        FreeStyle LibreLink,E0E84C13,날짜아님,0,136,,
        """
        let url = try makeCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try await GlucoseCSVReader().read(from: url, targetUnit: .mgDL)

        #expect(r.validRecords.isEmpty)
        // 예전에는 오류 0건으로 조용히 사라졌다
        #expect(r.invalidRecords.count == 1)
        #expect(r.invalidRecords.first?.lineNumber == 3)
    }

    /// 정상 파일에서도 어떤 행을 헤더로 건너뛰었는지 추적되어야 한다.
    @Test func headerRowsAreTracked() async throws {
        let csv = """
        혈당 데이터,생성일,2026-07-18 13:27 UTC,생성자,승준 오
        장치,일련 번호,장치 타임스탬프,기록 유형,과거 혈당 mg/dL,혈당 스캔 mg/dL
        FreeStyle LibreLink,E0E84C13,20-02-2026 22:34,0,136,,
        """
        let url = try makeCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try await GlucoseCSVReader().read(from: url, targetUnit: .mgDL)

        #expect(r.validRecords.count == 1)
        // 상단 헤더 2줄이 기록되어야 한다
        #expect(r.headerSkippedRows.count == 2)
        #expect(r.headerSkippedRows.allSatisfy { $0.lineNumber <= 2 })
    }
}
