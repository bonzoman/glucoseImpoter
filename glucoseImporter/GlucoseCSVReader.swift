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
    func read(from url: URL, targetUnit: GlucoseUnit?, manualConfig: ManualCSVFormat?, dateOrderOverride: DateComponentOrder?) async throws -> CSVParseResult
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
    ///   - dateOrderOverride: 일/월 순서를 사용자가 직접 지정한 경우 (nil이면 파일 스캔으로 자동 판단)
    /// - Returns: 안전하게 파싱된 `CSVParseResult` (성공/실패 분리)
    public func read(from url: URL, targetUnit: GlucoseUnit? = nil, manualConfig: ManualCSVFormat? = nil, dateOrderOverride: DateComponentOrder? = nil) async throws -> CSVParseResult {
        var validRecords: [GlucoseRecord] = []
        var invalidRecords: [CSVParseErrorRecord] = []
        var skippedCount = 0
        var skippedReason: String? = nil
        
        var detectedVendor: CSVVendorType = .custom
        let detectedUnit: GlucoseUnit = targetUnit ?? .mgDL
        var currentDetection: FormatDetection? = nil
        var isLibreFormat = false
        var isDexcomFormat = false
        var determinedDateFormat: String? = nil
        
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

        // 나라별 CSV 구조 판별: 세미콜론/탭 구분자를 쓰는 파일(유럽식) 대응
        let delimiter = CSVStructureDetector.detectDelimiter(lines: lines)

        // 모호한 일/월 순서(예: 03/05/2024)를 파일 전체를 스캔해 1회 결정.
        // 사용자가 미리보기에서 직접 지정했다면 그 값을 그대로 사용.
        //
        // 스캔 대상은 반드시 "실제 날짜가 들어있는 열"이어야 한다.
        // Libre는 2번 열(장치 타임스탬프), Dexcom은 1번 열이 날짜이며,
        // 0번 열을 보면 기기명 같은 문자열이라 판단 근거를 못 찾고
        // 기기 지역 설정으로 잘못 폴백된다.
        let ambiguityDateColumn: Int
        if let config = manualConfig {
            ambiguityDateColumn = config.dateColumnIndex
        } else if isLibreFormat {
            ambiguityDateColumn = 2
        } else if isDexcomFormat {
            ambiguityDateColumn = 1
        } else {
            ambiguityDateColumn = 0
        }
        let resolvedDateOrder = dateOrderOverride
            ?? FlexibleDateParser.resolveOrder(lines: lines, dateColumnIndex: ambiguityDateColumn, separator: delimiter)

        // 수동 매핑이 지정된 경우, 감지된 구분자를 반영해 파싱 규격을 확정
        if let config = manualConfig {
            detectedVendor = .custom
            currentDetection = createDetection(vendor: .custom, unit: targetUnit ?? .mgDL, dateIndex: config.dateColumnIndex, valueIndex: config.valueColumnIndex, recordTypeIndex: nil, dateFormat: config.dateFormat ?? "", separator: delimiter)
        }

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
                
                let components = trimmedLine.split(separator: delimiter, omittingEmptySubsequences: false)
                
                // 요구된 인덱스 규칙 준수를 위한 최소 컬럼 개수 확인 (스캔혈당은 인덱스 5)
                guard components.count >= 6 else {
                    if lineNumber <= 5 {
                        totalReadLines -= 1 // 헤더 행 무시
                    } else {
                        invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "Libre 데이터 컬럼 부족 (최소 6개 필요)")))
                    }
                    continue
                }
                
                let dateString = components[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let recordType = components[3].trimmingCharacters(in: .whitespacesAndNewlines)
                
                // 기록 유형(0 또는 1) 필터링 (그 외의 데이터는 예외 명시 후 스킵)
                if recordType != "0" && recordType != "1" {
                    skippedCount += 1
                    skippedReason = String(localized: "리브레 예외 데이터(무시됨)")
                    continue
                }
                
                // 날짜 파싱 (여러 나라 포맷 유연 파싱)
                var date: Date? = nil
                if let parsed = FlexibleDateParser.parse(dateString, order: resolvedDateOrder) {
                    date = parsed.date
                    determinedDateFormat = parsed.format
                }

                guard let validDate = date else {
                    if lineNumber <= 5 {
                        totalReadLines -= 1
                    } else {
                        invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "날짜 파싱 실패: \(dateString)")))
                    }
                    continue
                }
                
                // 값 추출 (기록 유형 0 -> 인덱스 4, 1 -> 인덱스 5)
                let valueIndex = (recordType == "0") ? 4 : 5
                let valueString = components[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard !valueString.isEmpty, let value = CSVStructureDetector.parseDecimal(valueString) else {
                    if lineNumber <= 5 {
                        totalReadLines -= 1
                    } else {
                        invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "혈당 수치 파싱 실패 (빈 값이거나 숫자 아님): \(valueString)")))
                    }
                    continue
                }
                
                // 단위 변환 불필요 (Libre CSV는 기본적으로 mg/dL이라고 간주하거나, 사용자 타겟 단위 맞춤. 여기서는 일단 그대로 수용)
                if value < 20.0 || value > 600.0 {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "정상 혈당 범위(20~600) 초과: \(value) mg/dL")))
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
                
                let components = trimmedLine.split(separator: delimiter, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\r\t")) }
                
                // Dexcom 데이터는 최소 8개 이상의 컬럼(Index, Timestamp, Event Type, Event Subtype, Patient Info, Device Info, Source Device ID, Glucose Value)
                guard components.count >= 8 else {
                    if lineNumber <= 15 {
                        totalReadLines -= 1
                    } else {
                        invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "Dexcom 데이터 컬럼 부족 (최소 8개 필요)")))
                    }
                    continue
                }
                
                let dateString = components[1]
                let eventType = components[2]
                let valueString = components[7]
                
                // Event Type이 'EGV' (Estimated Glucose Value)인 경우만 유효한 연속혈당값으로 인정하고 나머지는 Skip 처리
                guard eventType == "EGV" else {
                    skippedCount += 1
                    skippedReason = String(localized: "EGV 이외의 이벤트 무시 (\(eventType))")
                    continue
                }
                
                // Dexcom 고유 T-포맷 날짜 파싱
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone.current
                df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                
                guard let validDate = df.date(from: dateString) else {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "Dexcom 날짜 형식 파싱 실패: \(dateString)")))
                    continue
                }
                determinedDateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                
                guard !valueString.isEmpty, let value = CSVStructureDetector.parseDecimal(valueString) else {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "Dexcom 혈당치 변환 실패: \(valueString)")))
                    continue
                }
                
                if value < 20.0 || value > 600.0 {
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "Dexcom 정상 혈당 범위 초과: \(value) mg/dL")))
                    continue
                }
                
                validRecords.append(GlucoseRecord(timestamp: validDate, value: value))
                continue // Dexcom 파싱 스코프 완료
            }
            // --- Dexcom 고정 파싱 분기 종료 ---
            
            // 기존 비-Libre, 비-Dexcom 벤더의 헤더 감지 로직
            if !isLibreFormat && !isDexcomFormat && currentDetection == nil && detectedVendor != .custom {
                print("🔍 [CSVReader] L\(lineNumber) 감지: \(trimmedLine)")
                
                // 기존 Libre 헤더 감지 로직 제거
                // if (lowerLine.contains("혈당") && lowerLine.contains("시간")) || lowerLine.contains("historicglucose") || lowerLine.contains("기록혈당") || (lowerLine.contains("과거") && lowerLine.contains("mg/dl")) { ... }
                // else if isLibreFileHint && lineNumber <= 5 { ... }
                
                // 기존 Libre 헤더 감지 로직 제거
                
                if lineNumber <= 5 {
                    // 첫 몇 줄 범용 탐색: 단순 "날짜,값" 형태
                    let comps = trimmedLine.split(separator: delimiter, omittingEmptySubsequences: false)
                    if comps.count >= 2 {
                        let dateCandidate = String(comps[0].trimmingCharacters(in: .whitespacesAndNewlines))
                        let foundFormat = FlexibleDateParser.parse(dateCandidate, order: resolvedDateOrder)?.format

                        if let validFormat = foundFormat, CSVStructureDetector.parseDecimal(String(comps[1])) != nil {
                            detectedVendor = .custom
                            currentDetection = createDetection(vendor: .custom, unit: targetUnit ?? .mgDL, dateIndex: 0, valueIndex: 1, recordTypeIndex: nil, dateFormat: validFormat, separator: delimiter)
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
                    invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "포맷을 알 수 없어 파싱 불가")))
                }
                continue 
            }
            
            let components = trimmedLine.split(separator: format.separator, omittingEmptySubsequences: false)
            
            guard components.count > format.dateColumnIndex, components.count > format.valueColumnIndex else {
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "필수 컬럼 누락")))
                continue
            }
            
            let dateString = components[format.dateColumnIndex].trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\r\t"))
            let valueString = components[format.valueColumnIndex].trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\r\t"))
            
            // 날짜 파싱 시도: 사용자가 수동 지정한 포맷이 있으면 우선, 없으면 여러 나라 포맷 유연 파싱
            var date: Date? = nil
            if !format.dateFormatter.dateFormat.isEmpty, let d = format.dateFormatter.date(from: dateString) {
                date = d
                determinedDateFormat = format.dateFormatter.dateFormat
            } else if let parsed = FlexibleDateParser.parse(dateString, order: resolvedDateOrder) {
                date = parsed.date
                determinedDateFormat = parsed.format
            }
            
            guard let validDate = date else {
                // 수동 매핑 지정 시, 파일 최상단부(헤더 등)에서 날짜 포맷이 안 맞으면 조용히 무시 (오류 노출 방지)
                if manualConfig != nil && validRecords.isEmpty && lineNumber <= 15 {
                    totalReadLines -= 1 // 헤더로 취급하여 전체 카운트에서 제외
                    continue
                }
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "날짜 형식 오류: \(dateString)")))
                continue
            }
            
            guard let originalValue = CSVStructureDetector.parseDecimal(valueString) else {
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
                
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "수치 형식 오류 (빈 값 포함): \(valueString)")))
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
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: String(localized: "정상 혈당 범위(20~600) 초과: \(mgDLValue) mg/dL")))
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
            usedDateFormat: determinedDateFormat,
            usedDateOrder: resolvedDateOrder,
            detectedDelimiter: String(delimiter)
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
