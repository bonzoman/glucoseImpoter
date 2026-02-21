import Foundation

// Copying the relevant parts of GlucoseCSVReader to test the new logic
enum CSVVendorType { case libre, dexcom, custom, accuChek }
enum GlucoseUnit { 
    case mgDL, mmolL 
    func convertToMgDL(value: Double) -> Double { return self == .mmolL ? value * 18.0182 : value }
}
struct GlucoseRecord { let timestamp: Date; let value: Double }
struct CSVParseErrorRecord { let lineNumber: Int; let rawLine: String; let reason: String }
struct CSVParseResult {
    let vendor: CSVVendorType
    let originalUnit: GlucoseUnit
    let validRecords: [GlucoseRecord]
    let invalidRecords: [CSVParseErrorRecord]
}
struct FormatDetection {
    let vendor: CSVVendorType
    let unit: GlucoseUnit
    let dateFormatter: DateFormatter
    let dateColumnIndex: Int
    let valueColumnIndex: Int
    let recordTypeColumnIndex: Int?
    let separator: Character
}

class GlucoseCSVReader {
    public func read(from url: URL, targetUnit: GlucoseUnit? = nil) throws -> CSVParseResult {
        var validRecords: [GlucoseRecord] = []
        var invalidRecords: [CSVParseErrorRecord] = []
        var detectedVendor: CSVVendorType = .custom
        var detectedUnit: GlucoseUnit = targetUnit ?? .mgDL
        var currentDetection: FormatDetection? = nil
        // Libre mode flag
        var isLibreFormat = false
        
        let content = try readStringWithEncodings(from: url)
        let lines = content.components(separatedBy: .newlines)
        
        var lineNumber = 0
        for line in lines {
            lineNumber += 1
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            
            // --- Libre 고정 파싱 분기 ---
            let isLibreRow = trimmedLine.lowercased().hasPrefix("freestyle libre") || trimmedLine.lowercased().hasPrefix("freestylelibre")
            if isLibreRow {
                isLibreFormat = true
                detectedVendor = .libre
                
                let components = trimmedLine.split(separator: ",", omittingEmptySubsequences: false)
                
                // 요구된 인덱스 규칙 준수를 위한 최소 컬럼 개수 확인 (스캔혈당은 인덱스 5)
                guard components.count >= 6 else {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "Libre 데이터 컬럼 부족 (최소 6개 필요)"))
                    continue
                }
                
                let dateString = components[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let recordType = components[3].trimmingCharacters(in: .whitespacesAndNewlines)
                
                // 기록 유형(0 또는 1) 필터링
                if recordType != "0" && recordType != "1" {
                    continue // 에러 처리 없이 스킵
                }
                
                // 날짜 파싱 로직 통합
                var date: Date? = nil
                let fallbackFormatter = DateFormatter()
                fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
                fallbackFormatter.timeZone = TimeZone.current
                let fallbackFormats = ["yyyy.M.d HH:mm", "yyyy.MM.dd HH:mm", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm"]
                for fmt in fallbackFormats {
                    fallbackFormatter.dateFormat = fmt
                    if let d = fallbackFormatter.date(from: dateString) {
                        date = d
                        break
                    }
                }
                
                guard let validDate = date else {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "날짜 파싱 실패: \(dateString)"))
                    continue
                }
                
                // 값 추출 (기록 유형 0 -> 인덱스 4, 1 -> 인덱스 5)
                let valueIndex = (recordType == "0") ? 4 : 5
                let valueString = components[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard !valueString.isEmpty, let value = Double(valueString) else {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "혈당 수치 파싱 실패 (빈 값이거나 숫자 아님): \(valueString)"))
                    continue
                }
                
                if value < 20.0 || value > 600.0 {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "정상 혈당 범위(20~600) 초과: \(value) mg/dL"))
                    continue
                }
                
                validRecords.append(GlucoseRecord(timestamp: validDate, value: value))
                continue // Libre 파싱 스코프 완료
            }
            // --- Libre 고정 파싱 분기 종료 ---
            
            // 아래는 기존의 타 vendor(dexcom, accuchek, custom) 파싱 로직
            if !isLibreFormat && currentDetection == nil {
                let lowerLine = trimmedLine.lowercased().replacingOccurrences(of: " ", with: "")
                if lowerLine.contains("dexcom") || lowerLine.contains("glucosevalue") {
                    detectedVendor = .dexcom
                    detectedUnit = .mgDL
                    currentDetection = createDetection(vendor: .dexcom, unit: .mgDL, dateIndex: 1, valueIndex: 7, recordTypeIndex: nil, dateFormat: "yyyy-MM-dd HH:mm:ss")
                    continue
                } else if lowerLine.contains("accu-chek") {
                    detectedVendor = .accuChek
                    detectedUnit = .mgDL
                    currentDetection = createDetection(vendor: .accuChek, unit: .mgDL, dateIndex: 0, valueIndex: 1, recordTypeIndex: nil, dateFormat: "dd.MM.yyyy HH:mm", separator: ";")
                    continue
                } else if lineNumber <= 5 {
                    let comps = trimmedLine.split(separator: ",", omittingEmptySubsequences: false)
                    if comps.count >= 2 {
                        let cf = DateFormatter()
                        cf.locale = Locale(identifier: "en_US_POSIX")
                        cf.timeZone = TimeZone.current
                        let formatsToTest = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "MM/dd/yyyy HH:mm", "yyyy.MM.dd HH:mm", "yyyy.M.d HH:mm"]
                        var foundFormat: String?
                        for fmt in formatsToTest {
                            cf.dateFormat = fmt
                            if cf.date(from: String(comps[0].trimmingCharacters(in: .whitespacesAndNewlines))) != nil { foundFormat = fmt; break }
                        }
                        if let validFormat = foundFormat, Double(comps[1].trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                            detectedVendor = .custom
                            currentDetection = createDetection(vendor: .custom, unit: targetUnit ?? .mgDL, dateIndex: 0, valueIndex: 1, recordTypeIndex: nil, dateFormat: validFormat)
                        } else { continue }
                    } else { continue }
                } else { continue }
            }
            
            guard let format = currentDetection, !isLibreFormat else { continue }
            
            // 기존 FormatDetection 기반 파싱 루틴
            let components = trimmedLine.split(separator: format.separator, omittingEmptySubsequences: false)
            guard components.count > format.dateColumnIndex, components.count > format.valueColumnIndex else { continue }
            
            let dateString = components[format.dateColumnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueString = components[format.valueColumnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            
            var date = format.dateFormatter.date(from: dateString)
            if date == nil {
                let fallbackFormatter = DateFormatter()
                fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
                fallbackFormatter.timeZone = TimeZone.current
                let fallbackFormats = ["yyyy.M.d HH:mm", "yyyy.MM.dd HH:mm", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm"]
                for fmt in fallbackFormats {
                    fallbackFormatter.dateFormat = fmt
                    if let d = fallbackFormatter.date(from: dateString) { date = d; break }
                }
            }
            guard let validDate = date, let originalValue = Double(valueString) else { continue }
            let mgDLValue = format.unit.convertToMgDL(value: originalValue)
            if mgDLValue < 20.0 || mgDLValue > 600.0 { continue }
            
            validRecords.append(GlucoseRecord(timestamp: validDate, value: mgDLValue))
        }
        
        return CSVParseResult(vendor: detectedVendor, originalUnit: detectedUnit, validRecords: validRecords, invalidRecords: invalidRecords)
    }
    
    private func createDetection(vendor: CSVVendorType, unit: GlucoseUnit, dateIndex: Int, valueIndex: Int, recordTypeIndex: Int?, dateFormat: String, separator: Character = ",") -> FormatDetection {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return FormatDetection(vendor: vendor, unit: unit, dateFormatter: formatter, dateColumnIndex: dateIndex, valueColumnIndex: valueIndex, recordTypeColumnIndex: recordTypeIndex, separator: separator)
    }
    
    private func readStringWithEncodings(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        
        // 1. CP949 시도 - 더 관대하게 적용 (키워드 검사 생략, 실패 시 fallback)
        let eucKR = String.Encoding(rawValue: 0x80000422)
        if let eucKRString = String(data: data, encoding: eucKR) {
            return eucKRString
        }
        
        if let utf8String = String(data: data, encoding: .utf8) { return utf8String }
        if let utf16String = String(data: data, encoding: .utf16) { return utf16String }
        
        // 정 안되면 Lossy UTF8 시도
        return String(decoding: data, as: UTF8.self)
    }
}

let reader = GlucoseCSVReader()
do {
    let result = try reader.read(from: URL(fileURLWithPath: "/Users/sjo/xcode/glucoseImporter/222test.csv"))
    print("\n--- RESULTS ---")
    print("Vendor: \(result.vendor)")
    print("Valid Records: \(result.validRecords.count)")
    print("Invalid Records: \(result.invalidRecords.count)")
} catch {
    print("Error: \(error)")
}
