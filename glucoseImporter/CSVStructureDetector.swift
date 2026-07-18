import Foundation

/// CSV의 "구조"(구분자, 숫자 표기)를 나라별 관례에 맞게 판별한다.
///
/// 배경: 독일·프랑스 등에서는 Excel이 CSV를 세미콜론으로 구분하고 소수점에 콤마를 쓴다.
///   Datum;Glukose
///   25.03.2024 08:05;120,5
/// 콤마만 가정하면 이런 파일은 통째로 파싱에 실패한다.
public struct CSVStructureDetector {

    /// 우선순위 순서. 세미콜론·탭이 일관되게 나타나면 그것이 구분자이고,
    /// 그 경우 콤마는 소수점일 가능성이 높으므로 콤마보다 먼저 검사한다.
    private static let candidates: [Character] = [";", "\t", ","]

    /// 파일 앞부분을 표본으로 구분자를 판별한다. 판단 근거가 없으면 콤마.
    public static func detectDelimiter(lines: [String]) -> Character {
        let samples = lines
            .prefix(50)
            .map { $0.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !samples.isEmpty else { return "," }

        for candidate in candidates {
            let linesContaining = samples.filter { $0.contains(candidate) }.count
            // 표본의 80% 이상에서 등장하면 구분자로 인정
            if Double(linesContaining) >= Double(samples.count) * 0.8 {
                return candidate
            }
        }
        return ","
    }

    /// 나라별 소수점 표기를 흡수해 숫자로 변환한다.
    /// - "120.5" → 120.5 (표준)
    /// - "120,5" → 120.5 (유럽식 소수점 콤마)
    /// - "1.234,5" → 1234.5 (유럽식 천단위 점 + 소수점 콤마)
    ///
    /// 구분자가 콤마인 파일에서는 필드 안에 콤마가 들어올 수 없으므로 안전하다.
    public static func parseDecimal(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\r\t"))
        guard !s.isEmpty else { return nil }

        // 표준 표기 우선
        if let value = Double(s) { return value }

        guard s.contains(",") else { return nil }

        let normalized: String
        if s.contains(".") {
            // 점이 천단위 구분, 콤마가 소수점인 유럽식 (예: 1.234,5)
            normalized = s.replacingOccurrences(of: ".", with: "")
                          .replacingOccurrences(of: ",", with: ".")
        } else {
            normalized = s.replacingOccurrences(of: ",", with: ".")
        }
        return Double(normalized)
    }

    /// 사용자에게 보여줄 구분자 이름
    public static func displayName(for delimiter: Character) -> String {
        switch delimiter {
        case ";":  return String(localized: "세미콜론 (;)")
        case "\t": return String(localized: "탭")
        default:   return String(localized: "콤마 (,)")
        }
    }
}
