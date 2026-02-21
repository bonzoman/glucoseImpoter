import Foundation

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
        
        let content = try readStringWithEncodings(from: url)
        let lines = content.components(separatedBy: .newlines)
        print("📄 [CSVReader] 파일 읽기 완료: \(lines.count) lines")
        print("First 3 lines:")
        for i in 0..<min(3, lines.count) {
            print("[\(i)] \(lines[i])")
        }
        
        var lineNumber = 0
        for line in lines {
            lineNumber += 1
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            
            if currentDetection == nil {
                let lowerLine = trimmedLine.lowercased().replacingOccurrences(of: " ", with: "")
                print("L\(lineNumber) Header check: \(trimmedLine)")
                
                let isLibreFileHint = lowerLine.contains("freestylelibre") || lowerLine.contains("librelink") || lowerLine.contains("장치") || lowerLine.contains("기기")
                
                if (lowerLine.contains("혈당") && lowerLine.contains("시간")) || lowerLine.contains("historicglucose") || lowerLine.contains("기록혈당") || (lowerLine.contains("과거") && lowerLine.contains("mg/dl")) {
                    detectedVendor = .libre
                    detectedUnit = line.lowercased().contains("mmol/l") ? .mmolL : .mgDL
                    
                    let headers = trimmedLine.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "") }
                    print("✅ Libre Header Found: \(headers)")
                    
                    var dateIdx = 2; var typeIdx: Int? = 3; var valIdx = 4
                    if let d = headers.firstIndex(where: { $0.contains("시간") || $0.contains("time") }) { dateIdx = d }
                    if let t = headers.firstIndex(where: { $0.contains("유형") || $0.contains("type") }) { typeIdx = t }
                    if let v = headers.firstIndex(where: { $0.contains("혈당") || $0.contains("glucose") || $0.contains("과거") }) { valIdx = v }
                    
                    currentDetection = createDetection(vendor: .libre, unit: detectedUnit, dateIndex: dateIdx, valueIndex: valIdx, recordTypeIndex: typeIdx, dateFormat: "yyyy-MM-dd HH:mm", separator: ",") 
                    continue
                } else if isLibreFileHint && lineNumber <= 5 {
                    continue
                } else if lowerLine.contains("dexcom") || lowerLine.contains("glucosevalue") {
                    detectedVendor = .dexcom
                    currentDetection = createDetection(vendor: .dexcom, unit: .mgDL, dateIndex: 1, valueIndex: 7, recordTypeIndex: nil, dateFormat: "yyyy-MM-dd HH:mm:ss")
                    continue
                }
            }
            
            guard let format = currentDetection else { continue }
            
            let components = trimmedLine.split(separator: format.separator, omittingEmptySubsequences: false)
            guard components.count > format.dateColumnIndex, components.count > format.valueColumnIndex else {
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "필수 컬럼 누락"))
                continue
            }
            
            let dateString = components[format.dateColumnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueString = components[format.valueColumnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            
            var date = format.dateFormatter.date(from: dateString)
            if date == nil {
                let fallbackFormatter = DateFormatter()
                fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
                fallbackFormatter.timeZone = TimeZone.current
                let fallbackFormats = ["yyyy.M.d HH:mm", "yyyy.MM.dd HH:mm", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm", "yyyy. M. d. HH:mm", "yyyy. M. d HH:mm"]
                for fmt in fallbackFormats {
                    fallbackFormatter.dateFormat = fmt
                    if let d = fallbackFormatter.date(from: dateString) {
                        date = d
                        break
                    }
                }
            }
            
            guard let validDate = date else {
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "날짜 형식 오류: \(dateString)"))
                continue
            }
            
            guard let originalValue = Double(valueString) else {
                if let typeIdx = format.recordTypeColumnIndex, components.count > typeIdx {
                    let recordType = components[typeIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                    if recordType != "0" && recordType != "1" { continue }
                }
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "수치 오류: \(valueString)"))
                continue
            }
            
            if let typeIdx = format.recordTypeColumnIndex, components.count > typeIdx {
                let recordType = components[typeIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                if recordType != "0" && recordType != "1" { continue }
            }
            
            validRecords.append(GlucoseRecord(timestamp: validDate, value: format.unit.convertToMgDL(value: originalValue)))
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
        let fallback = String(decoding: data, as: UTF8.self)
        print("⚠️ 관대한 UTF-8 폴백 강제 시뮬레이션")
        return fallback
    }
}

let reader = GlucoseCSVReader()
do {
    let result = try reader.read(from: URL(fileURLWithPath: "/Users/sjo/xcode/glucoseImporter/222test.csv"))
    print("\n--- RESULTS ---")
    print("Valid Records: \(result.validRecords.count)")
    print("Invalid Records: \(result.invalidRecords.count)")
    if result.invalidRecords.count > 0 {
        print("\nFirst 5 invalid:")
        for r in result.invalidRecords.prefix(5) {
            print("L\(r.lineNumber): \(r.reason) | \(r.rawLine)")
        }
    }
} catch {
    print("Error: \(error)")
}
