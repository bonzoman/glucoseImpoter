import Foundation

/// 지원하는 CSV 공급업체 형식
public enum CSVVendorType: String, CaseIterable, Identifiable {
    case accuChek = "Accu-Chek"
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
}
