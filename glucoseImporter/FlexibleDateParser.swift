import Foundation

/// 일/월 컬럼의 순서. 슬래시·점 구분 날짜(예: 03/05/2024)에서만 의미가 있다.
public enum DateComponentOrder: Equatable {
    case dayFirst    // dd/MM/yyyy (한국·유럽 등 대부분)
    case monthFirst  // MM/dd/yyyy (미국)

    /// 반대 순서 (사용자가 미리보기에서 뒤집을 때 사용)
    public var flipped: DateComponentOrder {
        self == .dayFirst ? .monthFirst : .dayFirst
    }

    /// 사용자에게 보여줄 이름
    public var displayName: String {
        switch self {
        case .dayFirst:   return String(localized: "일/월/년 (25/03/2024)")
        case .monthFirst: return String(localized: "월/일/년 (03/25/2024)")
        }
    }
}

/// 여러 나라의 다양한 날짜 포맷을 파싱하기 위한 유연한 파서.
///
/// 핵심 원칙:
/// 1. 연도-먼저 포맷(yyyy-MM-dd 등)은 모호하지 않으므로 항상 먼저 시도한다.
/// 2. 일/월 순서가 모호한 포맷(03/05/2024)은 파일 전체를 스캔해 결정한 `DateComponentOrder`를 따른다.
/// 3. 엉뚱한 연도(예: 2자리 연도가 4자리 포맷에 잘못 매칭)로 조용히 틀리는 것을 막기 위해
///    파싱된 연도가 상식 범위를 벗어나면 매칭 실패로 간주한다.
public struct FlexibleDateParser {

    /// 연도-먼저·ISO 등 모호하지 않은 포맷 (항상 먼저 시도)
    static let unambiguousFormats: [String] = [
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
        "yyyy/MM/dd HH:mm:ss",
        "yyyy/MM/dd HH:mm",
        "yyyy/MM/dd",
        "yyyy.MM.dd HH:mm:ss",
        "yyyy.MM.dd HH:mm",
        "yyyy.M.d HH:mm",
        "yyyy.MM.dd",
    ]

    /// 일-먼저(dd/MM) 모호 포맷
    static let dayFirstFormats: [String] = [
        "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy",
        "d/M/yyyy HH:mm", "d/M/yyyy",
        "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm", "dd.MM.yyyy",
        "dd-MM-yyyy HH:mm", "dd-MM-yyyy",
        "dd/MM/yyyy hh:mm a",
    ]

    /// 월-먼저(MM/dd) 모호 포맷
    static let monthFirstFormats: [String] = [
        "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm", "MM/dd/yyyy",
        "M/d/yyyy HH:mm", "M/d/yyyy",
        "MM-dd-yyyy HH:mm", "MM-dd-yyyy",
        "MM/dd/yyyy hh:mm:ss a", "MM/dd/yyyy hh:mm a",
    ]

    private static func makeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.isLenient = false
        return f
    }

    /// 하나의 날짜 문자열을 파싱한다. 성공 시 (Date, 실제로 매칭된 포맷) 반환.
    /// - Parameters:
    ///   - raw: 날짜 문자열
    ///   - order: 모호한 일/월 포맷일 때 적용할 순서 (모호하지 않은 포맷엔 영향 없음)
    public static func parse(_ raw: String, order: DateComponentOrder) -> (date: Date, format: String)? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\r\t"))
        guard !s.isEmpty else { return nil }

        let formatter = makeFormatter()
        let ambiguous = (order == .dayFirst) ? dayFirstFormats : monthFirstFormats
        for fmt in unambiguousFormats + ambiguous {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: s), isPlausibleYear(d) {
                return (d, fmt)
            }
        }
        return nil
    }

    /// 파일 전체의 날짜 컬럼을 스캔해 일/월 순서를 결정한다.
    /// - 어떤 값의 첫 숫자가 12 초과면 dayFirst 확정, 둘째 숫자가 12 초과면 monthFirst 확정.
    /// - 판단 근거를 찾지 못하면(전부 12 이하) 기기 지역(Locale) 관례를 따른다.
    public static func resolveOrder(lines: [String], dateColumnIndex: Int, separator: Character = ",") -> DateComponentOrder {
        for line in lines {
            let trimmed = line.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let comps = trimmed.split(separator: separator, omittingEmptySubsequences: false)
            guard comps.count > dateColumnIndex else { continue }
            let field = comps[dateColumnIndex].trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\r\t"))
            if let decided = decideOrder(from: field) { return decided }
        }
        return localeDefaultOrder()
    }

    /// 해당 포맷이 일/월 순서가 모호한 종류인지 여부.
    /// 모호한 포맷으로 파싱됐을 때만 사용자에게 "순서 바꾸기"를 제안하면 된다.
    public static func isAmbiguousFormat(_ format: String) -> Bool {
        dayFirstFormats.contains(format) || monthFirstFormats.contains(format)
    }

    // MARK: - Private

    /// 파싱된 연도가 상식 범위(1990~2100) 안이면 true. 2자리 연도가 4자리 포맷에 잘못 매칭돼
    /// 연도 3, 24 같은 값이 나오는 조용한 오류를 막는다.
    private static func isPlausibleYear(_ date: Date) -> Bool {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return year >= 1990 && year <= 2100
    }

    /// 단일 값에서 일/월 순서를 확정할 수 있으면 반환, 없으면 nil.
    private static func decideOrder(from field: String) -> DateComponentOrder? {
        let tokens = field
            .components(separatedBy: CharacterSet(charactersIn: "/.-"))
            .prefix(3)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard tokens.count >= 3 else { return nil }
        // 연도-먼저(첫 토큰 4자리)는 모호하지 않으므로 판단 대상 아님
        if tokens[0].count == 4 { return nil }
        guard let first = Int(tokens[0]), let second = Int(tokens[1]) else { return nil }
        if first > 12 && first <= 31 { return .dayFirst }
        if second > 12 && second <= 31 { return .monthFirst }
        return nil
    }

    /// 기기 지역 설정의 날짜 관례에서 일/월 순서를 유추한다.
    /// (미국·한국 등 월이 일보다 앞서면 monthFirst, 유럽 등은 dayFirst)
    private static func localeDefaultOrder() -> DateComponentOrder {
        let template = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: .current) ?? "M/d"
        if let m = template.firstIndex(of: "M"), let d = template.firstIndex(of: "d") {
            return m < d ? .monthFirst : .dayFirst
        }
        return .monthFirst
    }
}
