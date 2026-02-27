import Foundation
import HealthKit

/// Apple HealthKit에 데이터를 저장할 때 발생할 수 있는 에러 타입
public enum HealthKitStoreError: Error, LocalizedError {
    case healthDataNotAvailable
    case permissionDenied
    case invalidQuantityType
    case saveFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .healthDataNotAvailable: return String(localized: "이 기기에서는 HealthKit을 사용할 수 없습니다.")
        case .permissionDenied: return String(localized: "혈당 기록 권한이 부여되지 않았습니다.")
        case .invalidQuantityType: return String(localized: "혈당(QuantityType)을 생성할 수 없습니다.")
        case .saveFailed(let error): 
            let format = String(localized: "저장 실패: %@")
            return String(format: format, error.localizedDescription)
        }
    }
}

/// HealthKit에 혈당 데이터를 안전하고 효율적으로 저장하기 위한 매니저 클래스
public final class HealthKitStoreManager {
    
    public static let shared = HealthKitStoreManager()
    private let healthStore: HKHealthStore
    private let glucoseType: HKQuantityType
    
    // 외부에선 shared(싱글톤) 혹은 DI를 통해서만 사용하도록 제어
    private init() {
        self.healthStore = HKHealthStore()
        
        // bloodGlucose 타입은 HealthKit에서 기본적으로 항상 존재하는 타입이므로 강제 언래핑 대신 옵셔널 바인딩 후 치명적 오류 처리
        guard let type = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else {
            fatalError("기기에서 Blood Glucose 타입을 지원하지 않습니다.")
        }
        self.glucoseType = type
    }
    
    /// HealthKit 읽기/쓰기 권한을 요청합니다.
    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitStoreError.healthDataNotAvailable
        }
        
        let typesToShare: Set<HKSampleType> = [glucoseType]
        let typesToRead: Set<HKObjectType> = [glucoseType]
        
        try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead)
    }
    
    /// 읽어온 CSV 혈당 데이터(`GlucoseRecord`) 배열을 HealthKit에 저장합니다.
    /// - Parameters:
    ///   - records: CSVReader를 통해 파싱된 `GlucoseRecord` 배열
    ///   - strategy: 중복 데이터 처리 방식 (.skip 또는 .overwrite)
    /// - Returns: 추가로 저장된(신규/덮어쓰기) 샘플의 개수 및 롤백을 위한 Batch ID
    public func saveGlucoseRecords(_ records: [GlucoseRecord]) async throws -> (Int, String) {
        guard !records.isEmpty else { return (0, "") }
        
        // 권한 확인 보장 (이론상 쓰기 권한이 없으면 아래 save 동작 시 에러 발생)
        if healthStore.authorizationStatus(for: glucoseType) != .sharingAuthorized {
            throw HealthKitStoreError.permissionDenied
        }
        
        // 1. 저장할 전체 기간 추출 (시작점 ~ 끝점)
        let sortedRecords = records.sorted { $0.timestamp < $1.timestamp }
        guard let startDate = sortedRecords.first?.timestamp,
              let endDate = sortedRecords.last?.timestamp else {
            return (0, "")
        }
        
        // 2. 해당 기간에 이미 저장된 HealthKit 데이터 조회 (중복 방지 용도)
        let existingSamples = try await fetchExistingSamples(from: startDate, to: endDate)
        
        // 중복 판별 최적화를 위해 Set 사용 (mg/dL 수치 단위까지 해시 처리)
        // HKQuantitySample은 고유의 UUID를 가지지만, 우리가 판별할 중복 기준은 '같은 시간대(분 단위)' + '같은 수치' 입니다.
        var existingSignatures = Set(existingSamples.map { sample -> String in
            let date = Int(sample.startDate.timeIntervalSince1970)
            let value = sample.quantity.doubleValue(for: HKUnit(from: "mg/dL"))
            return "\(date)_\(value)"
        })
        
        // 4. 필터링 및 변환 작업 (mg/dL 단위 명시)
        let mgDLUnit = HKUnit(from: "mg/dL")
        var samplesToSave: [HKQuantitySample] = []
        
        let batchID = UUID().uuidString
        
        for record in records {
            let signature = "\(Int(record.timestamp.timeIntervalSince1970))_\(record.value)"
            
            // 이미 동일한(시간+수치) 데이터가 있다면 (스킵 모드인 경우) 패스
            if existingSignatures.contains(signature) {
                continue
            }
            
            let quantity = HKQuantity(unit: mgDLUnit, doubleValue: record.value)
            
            // HealthKit은 보통 Start/End 타임이 존재하지만 혈당처럼 단발성 수치인 경우 동일하게 설정합니다.
            let sample = HKQuantitySample(
                type: glucoseType,
                quantity: quantity,
                start: record.timestamp,
                end: record.timestamp,
                metadata: [
                    HKMetadataKeyExternalUUID: record.id.uuidString, // 추적 용도
                    "ImportSource": "CSVImporter",                   // 메타데이터 브랜딩
                    "BatchID": batchID                               // 롤백용 배치 식별자
                ]
            )
            samplesToSave.append(sample)
        }
        
        // 5. Batch Save (비동기 배열 저장)
        if !samplesToSave.isEmpty {
            do {
                try await healthStore.save(samplesToSave)
                return (samplesToSave.count, batchID)
            } catch {
                throw HealthKitStoreError.saveFailed(error)
            }
        }
        
        return (0, batchID)
    }
    
    /// CSV 기준의 혈당 데이터가 이미 HealthKit에 저장되어 있는지 확인합니다.
    public func checkDuplicates(for records: [GlucoseRecord]) async throws -> Bool {
        guard let startDate = records.min(by: { $0.timestamp < $1.timestamp })?.timestamp,
              let endDate = records.max(by: { $0.timestamp < $1.timestamp })?.timestamp else {
            return false
        }
        
        // 해당 기간의 데이터가 1건이라도 있는지 로드
        let existingSamples = try await fetchExistingSamples(from: startDate, to: endDate.addingTimeInterval(1))
        return !existingSamples.isEmpty
    }
    
    // MARK: - Deletion & Rollback
    
    /// 특정 배치 ID를 가진 모든 혈당 데이터를 삭제합니다 (롤백 기능)
    public func rollbackBatch(batchID: String) async throws -> Int {
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(withMetadataKey: "BatchID", allowedValues: [batchID])
            
            let query = HKSampleQuery(sampleType: glucoseType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [weak self] _, samples, error in
                guard let self = self else { return }
                
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let validSamples = samples, !validSamples.isEmpty else {
                    continuation.resume(returning: 0)
                    return
                }
                
                self.healthStore.delete(validSamples) { success, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume(returning: validSamples.count)
                    } else {
                        continuation.resume(returning: 0)
                    }
                }
            }
            healthStore.execute(query)
        }
    }
    
    /// 지정된 날짜 범위 내에서 (이 앱이 생성한) 모든 혈당 데이터를 삭제하기 전 개수를 조회합니다.
    public func fetchDeleteTargetCount(from startDate: Date, to endDate: Date) async throws -> Int {
        return try await withCheckedThrowingContinuation { continuation in
            let datePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate.addingTimeInterval(1), options: .strictStartDate)
            let sourcePredicate = HKQuery.predicateForObjects(withMetadataKey: "ImportSource", allowedValues: ["CSVImporter"])
            let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, sourcePredicate])
            
            let query = HKSampleQuery(sampleType: glucoseType, predicate: compoundPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let count = samples?.count ?? 0
                continuation.resume(returning: count)
            }
            healthStore.execute(query)
        }
    }
    
    /// 지정된 날짜 범위 내에서 (이 앱이 생성한) 모든 혈당 데이터를 삭제합니다.
    public func deleteRecords(from startDate: Date, to endDate: Date) async throws -> Int {
        return try await withCheckedThrowingContinuation { continuation in
            // 1. 기간 조건
            let datePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate.addingTimeInterval(1), options: .strictStartDate)
            // 2. 이 앱에서 넣은 데이터인지 확인하는 조건 (메타데이터 브랜딩 일치 여부)
            let sourcePredicate = HKQuery.predicateForObjects(withMetadataKey: "ImportSource", allowedValues: ["CSVImporter"])
            
            let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, sourcePredicate])
            
            let query = HKSampleQuery(sampleType: glucoseType, predicate: compoundPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [weak self] _, samples, error in
                guard let self = self else { return }
                
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let validSamples = samples, !validSamples.isEmpty else {
                    continuation.resume(returning: 0)
                    return
                }
                
                self.healthStore.delete(validSamples) { success, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume(returning: validSamples.count)
                    } else {
                        continuation.resume(returning: 0)
                    }
                }
            }
            healthStore.execute(query)
        }
    }
    
    // MARK: - Private Helpers
    
    /// 지정된 기간 사이의 기존 혈당 데이터를 가져옵니다. (중복 검사용)
    private func fetchExistingSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate.addingTimeInterval(1), options: .strictStartDate)
            
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            
            let query = HKSampleQuery(
                sampleType: glucoseType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let quantitySamples = samples as? [HKQuantitySample] else {
                    // 빈 배열 반환
                    continuation.resume(returning: [])
                    return
                }
                
                continuation.resume(returning: quantitySamples)
            }
            
            healthStore.execute(query)
        }
    }
}
