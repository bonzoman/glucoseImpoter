import Foundation

// MARK: - Models

/// 혈당 수치(mg/dL)와 날짜를 담는 불변 객체.
/// Identifiable, Hashable을 채택하여 SwiftUI 리스트나 Diffable Data Source에서 즉시 사용 가능합니다.
public struct GlucoseRecord: Identifiable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let value: Double // mg/dL
    
    public init(id: UUID = UUID(), timestamp: Date, value: Double) {
        self.id = id
        self.timestamp = timestamp
        self.value = value
    }
}

// MARK: - Errors

/// CSV 파싱 시 발생할 수 있는 구체적인 에러 타입
public enum GlucoseCSVReaderError: Error, LocalizedError {
    case invalidRowFormat(line: Int, content: String)
    case invalidDateFormat(line: Int, content: String)
    case invalidValueFormat(line: Int, content: String)
    case unsupportedFormat
    
    public var errorDescription: String? {
        switch self {
        case .invalidRowFormat(let line, let content):
            return "형식이 잘못된 행입니다. (Line \(line)): \(content)"
        case .invalidDateFormat(let line, let content):
            return "날짜 형식이 잘못되었습니다. (Line \(line)): \(content)"
        case .invalidValueFormat(let line, let content):
            return "혈당 수치 형식이 잘못되었습니다. (Line \(line)): \(content)"
        case .unsupportedFormat:
            return "지원되지 않거나 인식할 수 없는 CSV 포맷입니다."
        }
    }
}

// MARK: - Reader Protocol

/// 테스트 용이성(Mocking)을 위한 프로토콜 정의
public protocol GlucoseCSVReading {
    func read(from url: URL, targetUnit: GlucoseUnit?, manualConfig: ManualCSVFormat?) async throws -> CSVParseResult
}

// MARK: - Reader Implementation

/// CSV 파일을 한 줄씩 읽어 GlucoseRecord 객체로 변환하는 클래스
public final class GlucoseCSVReader: GlucoseCSVReading {
    
    public init() {}
    
    // CSV 파싱 구조체
    private struct FormatDetection {
        let vendor: CSVVendorType
        let unit: GlucoseUnit
        let dateFormatter: DateFormatter
        let dateColumnIndex: Int
        let valueColumnIndex: Int
        let recordTypeColumnIndex: Int? // Libre용 '기록 유형' (Record Type) 파악용
        let separator: Character
    }

    /// CSV 파일 경로에서 데이터를 읽어 브랜드/포맷을 자동 유추하고 변환 결과를 반환합니다.
    /// - Parameters:
    ///   - url: CSV 파일의 로컬 URL 경로
    ///   - targetUnit: 강제할 수치 단위 (nil이면 헤더를 기반으로 자동 유추)
    ///   - manualConfig: 수동 매핑 설정 (제공 시 자동 감지 생략)
    /// - Returns: 안전하게 파싱된 `CSVParseResult` (성공/실패 분리)
    public func read(from url: URL, targetUnit: GlucoseUnit? = nil, manualConfig: ManualCSVFormat? = nil) async throws -> CSVParseResult {
        var validRecords: [GlucoseRecord] = []
        var invalidRecords: [CSVParseErrorRecord] = []
        var skippedCount = 0
        var skippedReason: String? = nil
        
        var detectedVendor: CSVVendorType = .custom
        var detectedUnit: GlucoseUnit = targetUnit ?? .mgDL
        var currentDetection: FormatDetection? = nil
        var isLibreFormat = false
        var isDexcomFormat = false
        var determinedDateFormat: String? = nil
        
        if let config = manualConfig {
            detectedVendor = .custom
            currentDetection = createDetection(vendor: .custom, unit: targetUnit ?? .mgDL, dateIndex: config.dateColumnIndex, valueIndex: config.valueColumnIndex, recordTypeIndex: nil, dateFormat: config.dateFormat ?? "")
        }
        
        // 1. 인코딩 처리: UTF-8 시도 후 실패하면 CP949(EUC-KR) 시도, 정 안되면 Lossy UTF8
        let content = try readStringWithEncodings(from: url)
        
        // 글로벌 Pre-sniffing
        let preSniffLength = min(content.count, 1000)
        let prefixString = String(content.prefix(preSniffLength)).lowercased()
        if prefixString.contains("freestyle libre") || prefixString.contains("freestylelibre") {
            isLibreFormat = true
            detectedVendor = .libre
            print("👁️ [CSVReader] 글로벌 스니핑 완료: Libre 포맷 사전 확정")
        } else if prefixString.contains("timestamp (yyyy-mm-ddthh:mm:ss)") || prefixString.contains("glucose value (mg/dl)") {
            isDexcomFormat = true
            detectedVendor = .dexcom
            print("👁️ [CSVReader] 글로벌 스니핑 완료: Dexcom 포맷 사전 확정")
        }
        
        let lines = content.components(separatedBy: "\n")
        
        print("📄 [CSVReader] 파일 읽기 시작 (총 \(lines.count)줄)")
        
        var lineNumber = 0
        var totalReadLines = 0
        for line in lines {
            lineNumber += 1
            // \r 찌꺼기 제거 및 공백 트림
            let trimmedLine = line.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            totalReadLines += 1
            
            // --- Libre 고정 파싱 분기 ---
            let isLibreRow = trimmedLine.lowercased().hasPrefix("freestyle libre") || trimmedLine.lowercased().hasPrefix("freestylelibre")
            if isLibreRow && currentDetection == nil {
                isLibreFormat = true
                detectedVendor = .libre
                
                let components = trimmedLine.split(separator: ",", omittingEmptySubsequences: false)
                
                // 요구된 인덱스 규칙 준수를 위한 최소 컬럼 개수 확인 (스캔혈당은 인덱스 5)
                guard components.count >= 6 else {
                    if lineNumber <= 5 {
                        totalReadLines -= 1 // 헤더 행 무시
                    } else {
                        invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "Libre 데이터 컬럼 부족 (최소 6개 필요)"))
                    }
                    continue
                }
                
                let dateString = components[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let recordType = components[3].trimmingCharacters(in: .whitespacesAndNewlines)
                
                // 기록 유형(0 또는 1) 필터링 (그 외의 데이터는 예외 명시 후 스킵)
                if recordType != "0" && recordType != "1" {
                    skippedCount += 1
                    skippedReason = "리브레 예외 데이터(무시됨)"
                    continue
                }
                
                // 날짜 파싱
                var date: Date? = nil
                let fallbackFormatter = DateFormatter()
                fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
                fallbackFormatter.timeZone = TimeZone.current
                let fallbackFormats = ["yyyy.M.d HH:mm", "yyyy.MM.dd HH:mm", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm"]
                for fmt in fallbackFormats {
                    fallbackFormatter.dateFormat = fmt
                    if let d = fallbackFormatter.date(from: dateString) {
                        date = d
                        determinedDateFormat = fmt
                        break
                    }
                }
                
                guard let validDate = date else {
                    if lineNumber <= 5 {
                        totalReadLines -= 1
                    } else {
                        invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "날짜 파싱 실패: \(dateString)"))
                    }
                    continue
                }
                
                // 값 추출 (기록 유형 0 -> 인덱스 4, 1 -> 인덱스 5)
                let valueIndex = (recordType == "0") ? 4 : 5
                let valueString = components[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard !valueString.isEmpty, let value = Double(valueString) else {
                    if lineNumber <= 5 {
                        totalReadLines -= 1
                    } else {
                        invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "혈당 수치 파싱 실패 (빈 값이거나 숫자 아님): \(valueString)"))
                    }
                    continue
                }
                
                // 단위 변환 불필요 (Libre CSV는 기본적으로 mg/dL이라고 간주하거나, 사용자 타겟 단위 맞춤. 여기서는 일단 그대로 수용)
                if value < 20.0 || value > 600.0 {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "정상 혈당 범위(20~600) 초과: \(value) mg/dL"))
                    continue
                }
                
                validRecords.append(GlucoseRecord(timestamp: validDate, value: value))
                continue // Libre 파싱 스코프 완료
            } else if isLibreFormat {
                // 상단 헤더행 중 시작 문구가 'Freestyle Libre'가 아닌 행(예: '이름,홍길동') 배제
                if lineNumber <= 5 {
                    totalReadLines -= 1
                    continue
                }
            }
            // --- Libre 고정 파싱 분기 종료 ---
            
            // --- Dexcom 고정 파싱 분기 ---
            if isDexcomFormat {
                // Dexcom 파일의 상단 11줄 가량은 환자/기기 정보 메타데이터이므로 패스
                if lineNumber <= 12 && !trimmedLine.lowercased().starts(with: "index") {
                    totalReadLines -= 1
                    continue
                }
                
                let components = trimmedLine.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\r\t")) }
                
                // Dexcom 데이터는 최소 8개 이상의 컬럼(Index, Timestamp, Event Type, Event Subtype, Patient Info, Device Info, Source Device ID, Glucose Value)
                guard components.count >= 8 else {
                    if lineNumber <= 15 {
                        totalReadLines -= 1
                    } else {
                        invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "Dexcom 데이터 컬럼 부족 (최소 8개 필요)"))
                    }
                    continue
                }
                
                let dateString = components[1]
                let eventType = components[2]
                let valueString = components[7]
                
                // Event Type이 'EGV' (Estimated Glucose Value)인 경우만 유효한 연속혈당값으로 인정하고 나머지는 Skip 처리
                guard eventType == "EGV" else {
                    skippedCount += 1
                    skippedReason = "EGV 이외의 이벤트 무시 (\(eventType))"
                    continue
                }
                
                // Dexcom 고유 T-포맷 날짜 파싱
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone.current
                df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                
                guard let validDate = df.date(from: dateString) else {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "Dexcom 날짜 형식 파싱 실패: \(dateString)"))
                    continue
                }
                determinedDateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                
                guard !valueString.isEmpty, let value = Double(valueString) else {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "Dexcom 혈당치 변환 실패: \(valueString)"))
                    continue
                }
                
                if value < 20.0 || value > 600.0 {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "Dexcom 정상 혈당 범위 초과: \(value) mg/dL"))
                    continue
                }
                
                validRecords.append(GlucoseRecord(timestamp: validDate, value: value))
                continue // Dexcom 파싱 스코프 완료
            }
            // --- Dexcom 고정 파싱 분기 종료 ---
            
            // 기존 비-Libre, 비-Dexcom 벤더의 헤더 감지 로직
            if !isLibreFormat && !isDexcomFormat && currentDetection == nil && detectedVendor != .custom {
                let lowerLine = trimmedLine.lowercased().replacingOccurrences(of: " ", with: "")
                print("🔍 [CSVReader] L\(lineNumber) 감지: \(trimmedLine)")
                
                // 기존 Libre 헤더 감지 로직 제거
                // if (lowerLine.contains("혈당") && lowerLine.contains("시간")) || lowerLine.contains("historicglucose") || lowerLine.contains("기록혈당") || (lowerLine.contains("과거") && lowerLine.contains("mg/dl")) { ... }
                // else if isLibreFileHint && lineNumber <= 5 { ... }
                
                // 기존 Libre 헤더 감지 로직 제거
                
                if lowerLine.contains("accu-chek") {
                    detectedVendor = .accuChek
                    detectedUnit = .mgDL
                    currentDetection = createDetection(vendor: .accuChek, unit: .mgDL, dateIndex: 0, valueIndex: 1, recordTypeIndex: nil, dateFormat: "dd.MM.yyyy HH:mm", separator: ";")
                    continue
                } else if lineNumber <= 5 {
                    // 첫 몇 줄 범용 탐색: 단순 "날짜,값" 형태
                    let comps = trimmedLine.split(separator: ",", omittingEmptySubsequences: false)
                    if comps.count >= 2 {
                        let cf = DateFormatter()
                        cf.locale = Locale(identifier: "en_US_POSIX")
                        cf.timeZone = TimeZone.current
                        
                        let formatsToTest = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "MM/dd/yyyy HH:mm", "yyyy.MM.dd HH:mm", "yyyy.M.d HH:mm"]
                        var foundFormat: String?
                        for fmt in formatsToTest {
                            cf.dateFormat = fmt
                            if cf.date(from: String(comps[0].trimmingCharacters(in: .whitespacesAndNewlines))) != nil {
                                foundFormat = fmt
                                break
                            }
                        }
                        
                        if let validFormat = foundFormat, Double(comps[1].trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                            detectedVendor = .custom
                            currentDetection = createDetection(vendor: .custom, unit: targetUnit ?? .mgDL, dateIndex: 0, valueIndex: 1, recordTypeIndex: nil, dateFormat: validFormat)
                        } else {
                            totalReadLines -= 1 // 헤더 행 등으로 간주하여 데이터 총건수에서 제외
                            continue
                        }
                    } else {
                        totalReadLines -= 1 // 헤더 행 등으로 간주하여 데이터 총건수에서 제외
                        continue
                    }
                } else {
                    if lineNumber > 20 && currentDetection == nil {
                        // 에러를 던지지 않고 Custom 포맷으로 전환하여 계속 파싱(실패 처리) 유도
                        detectedVendor = .custom
                    } else {
                        totalReadLines -= 1 // 포맷 감지 전의 기타 불필요 구문으로 간주
                        continue
                    }
                }
            }
            
            // 기존 FormatDetection 기반 벤더 (Dexcom, AccuChek, Custom) 파싱 수행
            guard let format = currentDetection, !isLibreFormat else {
                if !isLibreFormat {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "포맷을 알 수 없어 파싱 불가"))
                }
                continue 
            }
            
            let components = trimmedLine.split(separator: format.separator, omittingEmptySubsequences: false)
            
            guard components.count > format.dateColumnIndex, components.count > format.valueColumnIndex else {
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "필수 컬럼 누락"))
                continue
            }
            
            let dateString = components[format.dateColumnIndex].trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\r\t"))
            let valueString = components[format.valueColumnIndex].trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\r\t"))
            
            // 날짜 파싱 시도 (기본 포맷 먼저, 안되면 추가 포맷 시도)
            var date = format.dateFormatter.date(from: dateString)
            if date != nil {
                determinedDateFormat = format.dateFormatter.dateFormat
            } else {
                let fallbackFormatter = DateFormatter()
                fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
                fallbackFormatter.timeZone = TimeZone.current
                // mm/dd/yyyy 포맷도 자동인식 목록에 추가
                let fallbackFormats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy.M.d HH:mm", "yyyy.MM.dd HH:mm", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm", "MM/dd/yyyy HH:mm", "MM/dd/yyyy HH:mm:ss", "dd.MM.yyyy HH:mm"]
                for fmt in fallbackFormats {
                    fallbackFormatter.dateFormat = fmt
                    if let d = fallbackFormatter.date(from: dateString) {
                        date = d
                        determinedDateFormat = fmt
                        break
                    }
                }
            }
            
            guard let validDate = date else {
                // 수동 매핑 지정 시, 파일 최상단부(헤더 등)에서 날짜 포맷이 안 맞으면 조용히 무시 (오류 노출 방지)
                if manualConfig != nil && validRecords.isEmpty && lineNumber <= 15 {
                    totalReadLines -= 1 // 헤더로 취급하여 전체 카운트에서 제외
                    continue
                }
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "날짜 형식 오류: \(dateString)"))
                continue
            }
            
            guard let originalValue = Double(valueString) else {
                if let typeIdx = format.recordTypeColumnIndex, components.count > typeIdx {
                    let recordType = components[typeIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                    if recordType != "0" && recordType != "1" {
                        continue
                    }
                }
                
                // 수동 매핑 지정 시, 파일 최상단부(헤더)에서 수치 변환 실패 시 조용히 무시
                if manualConfig != nil && validRecords.isEmpty && lineNumber <= 15 {
                    totalReadLines -= 1 // 헤더로 취급하여 전체 카운트에서 제외
                    continue
                }
                
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "수치 형식 오류 (빈 값 포함): \(valueString)"))
                continue
            }
            
            if let typeIdx = format.recordTypeColumnIndex, components.count > typeIdx {
                let recordType = components[typeIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                if recordType != "0" && recordType != "1" {
                    continue
                }
            }
            
            let mgDLValue = format.unit.convertToMgDL(value: originalValue)
            
            if mgDLValue < 20.0 || mgDLValue > 600.0 {
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "정상 혈당 범위(20~600) 초과: \(mgDLValue) mg/dL"))
                continue
            }
            validRecords.append(GlucoseRecord(timestamp: validDate, value: mgDLValue))
        }
        
        return CSVParseResult(
            vendor: detectedVendor,
            originalUnit: detectedUnit,
            validRecords: validRecords,
            invalidRecords: invalidRecords,
            skippedCount: skippedCount,
            skippedReason: skippedReason,
            totalReadLines: totalReadLines,
            usedDateFormat: determinedDateFormat
        )
    }
    
    // 이 위치에 read()를 닫는 괄호 추가!
    
    private func createDetection(vendor: CSVVendorType, unit: GlucoseUnit, dateIndex: Int, valueIndex: Int, recordTypeIndex: Int?, dateFormat: String, separator: Character = ",") -> FormatDetection {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        
        return FormatDetection(
            vendor: vendor,
            unit: unit,
            dateFormatter: formatter,
            dateColumnIndex: dateIndex,
            valueColumnIndex: valueIndex,
            recordTypeColumnIndex: recordTypeIndex,
            separator: separator
        )
    }
    
    /// 인코딩을 자동 감지하거나 여러 인코딩을 시도하여 파일 내용을 읽습니다.
    private func readStringWithEncodings(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        
        // 1. CP949 / EUC-KR (rawValue 0x80000422) 먼저 시도하여 키워드 유효성 확인
        // 한국어 Libre 파일은 십중팔구 CP949이며, '기록', '장치', '혈당', '시간' 등의 글자가 포함되어야 함
        let eucKR = String.Encoding(rawValue: 0x80000422)
        if let eucKRString = String(data: data, encoding: eucKR) {
            let lowerContent = eucKRString.lowercased()
            if lowerContent.contains("기록") || lowerContent.contains("장치") || lowerContent.contains("혈당") || lowerContent.contains("시간") || lowerContent.contains("모델") || lowerContent.contains("freestyle") || lowerContent.contains("mg/dl") {
                print("✅ [CSVReader] CP949(EUC-KR) 인코딩으로 유효한 한국어 키워드 확인")
                return eucKRString
            }
        }
        
        // 2. UTF-8 시도
        if let utf8String = String(data: data, encoding: .utf8) {
            return utf8String
        }
        
        // 3. UTF-16 시도
        if let utf16String = String(data: data, encoding: .utf16) {
            return utf16String
        }
        
        // 4. 관대한 UTF-8 디코딩 (REPLACEMENT CHARACTER 사용)
        print("⚠️ [CSVReader] 인코딩 감지 실패, 관대한 UTF-8 방식으로 시도")
        return String(decoding: data, as: UTF8.self)
    }
}
