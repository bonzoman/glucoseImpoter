import Foundation

/// 지원하는 CSV 공급업체 형식
public enum CSVVendorType: String, CaseIterable, Identifiable {
    case dexcom = "Dexcom"
    case libre = "Freestyle Libre"
    case custom = "Custom/Unknown"
    
    public var id: String { self.rawValue }
}

/// 혈당 수치 단위
public enum GlucoseUnit: String, CaseIterable, Identifiable {
    case mgDL = "mg/dL"
    case mmolL = "mmol/L"
    
    public var id: String { self.rawValue }
    
    /// HealthKit 저장을 위해 mg/dL로 변환합니다.
    public func convertToMgDL(value: Double) -> Double {
        switch self {
        case .mgDL:
            return value
        case .mmolL:
            // 1 mmol/L ≒ 18.0182 mg/dL
            return value * 18.0182
        }
    }
}

/// 파싱 과정에서 발생한 에러 기록
public struct CSVParseErrorRecord: Identifiable, Equatable {
    public let id = UUID()
    public let lineNumber: Int
    public let rawLine: String
    public let reason: String
}

/// 파싱 결과 (성공 레코드와 실패 내역을 모두 포함)
public struct CSVParseResult: Equatable {
    public let vendor: CSVVendorType
    public let originalUnit: GlucoseUnit
    public var validRecords: [GlucoseRecord]
    public var invalidRecords: [CSVParseErrorRecord]
    public var skippedCount: Int
    public var skippedReason: String?
    public var totalReadLines: Int // 파싱 시 읽어들인 실제 데이터 행 수
    public var usedDateFormat: String? // 파싱 시 확정되어 사용된 날짜 포맷
    public var usedDateOrder: DateComponentOrder // 일/월 순서 (모호한 포맷일 때 의미 있음)
    public var detectedDelimiter: String // 감지된 컬럼 구분자 (",", ";", "\t")
    /// 헤더/메타데이터로 간주해 건너뛴 행 (최대 20건).
    /// 임포트가 0건일 때 원인을 사용자에게 보여주기 위한 진단 정보.
    public var headerSkippedRows: [CSVParseErrorRecord]
}

/// 사용자가 직접 지정하는 수동 CSV 파싱 명세
public struct ManualCSVFormat: Equatable {
    public let dateColumnIndex: Int
    public let valueColumnIndex: Int
    public let dateFormat: String?
    
    public init(dateColumnIndex: Int, valueColumnIndex: Int, dateFormat: String? = nil) {
        self.dateColumnIndex = dateColumnIndex
        self.valueColumnIndex = valueColumnIndex
        self.dateFormat = dateFormat
    }
}
