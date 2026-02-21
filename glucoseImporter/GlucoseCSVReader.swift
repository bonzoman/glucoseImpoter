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
    func read(from url: URL, targetUnit: GlucoseUnit?) async throws -> CSVParseResult
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
    /// - Returns: 안전하게 파싱된 `CSVParseResult` (성공/실패 분리)
    public func read(from url: URL, targetUnit: GlucoseUnit? = nil) async throws -> CSVParseResult {
        var validRecords: [GlucoseRecord] = []
        var invalidRecords: [CSVParseErrorRecord] = []
        
        var lineNumber = 0
        var detectedVendor: CSVVendorType = .custom
        var detectedUnit: GlucoseUnit = targetUnit ?? .mgDL
        
        var currentDetection: FormatDetection? = nil
        
        // 비동기 스트리밍 방식으로 파일 읽기 (메모리 절약)
        for try await line in url.lines {
            lineNumber += 1
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            
            // 1. 헤더 유추 및 포맷 식별 (첫 1~3줄 이내 발생)
            if currentDetection == nil {
                // 이 부분을 더 고도화할 수 있으나, 이번 버전에서는 대표적인 힌트로 분기합니다.
                let lowerLine = trimmedLine.lowercased()
                
                if lowerLine.contains("dexcom") || lowerLine.contains("glucose value (mg/dl)") {
                    detectedVendor = .dexcom
                    detectedUnit = .mgDL
                    currentDetection = createDetection(vendor: .dexcom, unit: .mgDL, dateIndex: 1, valueIndex: 7, recordTypeIndex: nil, dateFormat: "yyyy-MM-dd HH:mm:ss")
                    continue
                } else if lowerLine.contains("freestyle libre") || lowerLine.contains("device") {
                    // Libre는 파일 상단에 헤더 정보와 공백이 존재함. 이 라인은 건너뜀
                    continue
                } else if lowerLine.contains("historic glucose") || lowerLine.contains("기록 혈당") {
                    // 실제 헤더가 있는 줄을 찾았을 때 동적 인덱스 추출
                    detectedVendor = .libre
                    detectedUnit = lowerLine.contains("mmol/l") ? .mmolL : .mgDL
                    
                    let headers = trimmedLine.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    
                    print("✅ [CSVReader] Libre 헤더 발견 파싱: \(headers)")
                    
                    // 기본값 세팅
                    var dateIdx = 2
                    var typeIdx: Int? = 3
                    var valIdx = 4
                    
                    if let d = headers.firstIndex(where: { $0.contains("시간") || $0.contains("time") }) { dateIdx = d }
                    if let t = headers.firstIndex(where: { $0.contains("기록 유형") || $0.contains("record type") }) { typeIdx = t }
                    if let v = headers.firstIndex(where: { $0.contains("기록 혈당") || $0.contains("historic glucose") }) { valIdx = v }
                    
                    print("✅ [CSVReader] Libre 추출된 인덱스 -> 날짜: \(dateIdx), 기록유형: \(typeIdx ?? -1), 혈당값: \(valIdx)")
                    
                    currentDetection = createDetection(vendor: .libre, unit: detectedUnit, dateIndex: dateIdx, valueIndex: valIdx, recordTypeIndex: typeIdx, dateFormat: "yyyy-MM-dd HH:mm", separator: ",") 
                    continue
                } else if lowerLine.contains("accu-chek") {
                    // Accu-chek 포맷 매핑
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
                        
                        let formatsToTest = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "MM/dd/yyyy HH:mm"]
                        var foundFormat: String?
                        for fmt in formatsToTest {
                            cf.dateFormat = fmt
                            if cf.date(from: String(comps[0].trimmingCharacters(in: .whitespacesAndNewlines))) != nil {
                                foundFormat = fmt
                                break
                            }
                        }
                        
                        if let validFormat = foundFormat, Double(comps[1].trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                            // 커스텀 성공
                            detectedVendor = .custom
                            currentDetection = createDetection(vendor: .custom, unit: targetUnit ?? .mgDL, dateIndex: 0, valueIndex: 1, recordTypeIndex: nil, dateFormat: validFormat)
                            // 헤더가 아니었으므로 해당 라인은 바로 파싱 진행
                        } else {
                            continue // 아직 헤더쪽이거나 알수없는줄
                        }
                    } else {
                        continue
                    }
                } else {
                    if lineNumber > 20 && currentDetection == nil {
                        throw GlucoseCSVReaderError.unsupportedFormat
                    }
                    continue
                }
            }
            
            // 2. 포맷이 인지된 상태에서 데이터 행 파싱
            guard let format = currentDetection else { continue }
            
            let components = trimmedLine.split(separator: format.separator, omittingEmptySubsequences: false)
            
            // 인덱스 안전성 검사
            guard components.count > format.dateColumnIndex, components.count > format.valueColumnIndex else {
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "필수 컬럼 누락"))
                continue
            }
            
            let dateString = components[format.dateColumnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueString = components[format.valueColumnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard let date = format.dateFormatter.date(from: dateString) else {
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "날짜 형식 오류: \(dateString)"))
                continue
            }
            
            guard let originalValue = Double(valueString) else {
                // 수치가 비어있는 경우는 메모, 식사 등의 기록일 수 있음 (에러처리 안하고 스킵할 기록 유형 확인)
                if let typeIdx = format.recordTypeColumnIndex, components.count > typeIdx {
                    let recordType = components[typeIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                    // Libre의 경우 "0" (자동스캔) 이나 "1" (스캔) 이 아닌 것은 혈당 기록이 아닌 일상 메모
                    if recordType != "0" && recordType != "1" {
                        continue // 에러가 아닌 정상적인 스킵 (메모, 식단, 인슐린 등)
                    }
                }
                
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "수치 형식 오류 (빈 값 포함): \(valueString)"))
                continue
            }
            
            // 수치가 존재하더라도, 기록 유형이 혈당 스캔이 아니면 스킵
            if let typeIdx = format.recordTypeColumnIndex, components.count > typeIdx {
                let recordType = components[typeIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                if recordType != "0" && recordType != "1" {
                    continue
                }
            }
            
            // 자동 단위 변환 로직 (mmol/L -> mg/dL)
            let mgDLValue = format.unit.convertToMgDL(value: originalValue)
            
            // 이상치(에러값) 식별 (혈당값이 20 미만이거나 600 초과인 경우 에러 처리)
            if mgDLValue < 20.0 || mgDLValue > 600.0 {
                invalidRecords.append(CSVParseErrorRecord(lineNumber: lineNumber, rawLine: trimmedLine, reason: "정상 혈당 범위(20~600) 초과: \(mgDLValue) mg/dL"))
                continue
            }
            
            validRecords.append(GlucoseRecord(timestamp: date, value: mgDLValue))
        }
        
        return CSVParseResult(
            vendor: detectedVendor,
            originalUnit: detectedUnit,
            validRecords: validRecords,
            invalidRecords: invalidRecords
        )
    }
    
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
}
