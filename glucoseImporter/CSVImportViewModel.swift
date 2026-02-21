import SwiftUI
import Combine

@MainActor
public final class CSVImportViewModel: ObservableObject {
    @Published public var parseResult: CSVParseResult? = nil
    @Published public var isImporting = false
    @Published public var errorMessage: String? = nil
    
    // UI 표시용 상태
    @Published public var previewRecords: [GlucoseRecord] = []
    @Published public var lastSavedBatchID: String? = nil
    
    public enum DuplicateStrategy {
        case skip
        case overwrite
    }
    
    @Published public var showDuplicateAlert = false
    @Published public var duplicateStrategy: DuplicateStrategy = .skip
    
    // 탭 및 Action 상태
    @Published public var selectedTab: Int = 0 // 0: 성공건, 1: 오류건
    @Published public var showSaveConfirmation = false
    
    public init() {}
    
    public func loadCSV(from url: URL) {
        Task {
            isImporting = true
            errorMessage = nil
            do {
                let reader = GlucoseCSVReader()
                let result = try await reader.read(from: url)
                
                self.parseResult = result
                // 미리보기는 최대 100건까지만 노출
                self.previewRecords = Array(result.validRecords.prefix(100))
                
            } catch {
                self.errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
    
    /// 저장 확인 요청
    public func requestSave() {
        showSaveConfirmation = true
    }
    
    /// HealthKit 저장 파이프라인 시작 (Save Confirm 후 호출)
    public func startHealthKitSave() {
        guard let result = parseResult, !result.validRecords.isEmpty else { return }
        
        Task {
            isImporting = true
            do {
                // 1. 중복 데이터 존재 여부 먼저 확인 (HealthKitStoreManager에 있는 fetchExistingSamples를 public으로 개방하거나, 내부적으로 개수만 받아오는 함수 신설 필요)
                // 간단한 구현을 위해 여기서는 무조건 한 번 저장을 시도하되, 내부 로직에 의해 skip할지 overwrite할지 넘기는 방식을 씁니다.
                // 중복 경고를 확실히 띄우려면 checkDuplicates 함수를 매니저에 추가해야 합니다.
                
                let hasDuplicates = try await HealthKitStoreManager.shared.checkDuplicates(for: result.validRecords)
                
                if hasDuplicates {
                    self.showDuplicateAlert = true
                } else {
                    // 중복이 없으면 바로 저장
                    self.saveToHealthKit(strategy: .skip)
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
    
    /// 실제 HealthKit 저장 수행
    public func saveToHealthKit(strategy: DuplicateStrategy) {
        guard let result = parseResult, !result.validRecords.isEmpty else { return }
        
        Task {
            isImporting = true
            do {
                let (savedCount, batchID) = try await HealthKitStoreManager.shared.saveGlucoseRecords(result.validRecords, strategy: strategy)
                print("저장 완료: \(savedCount)건 (Strategy: \(strategy), Batch: \(batchID))")
                
                self.lastSavedBatchID = batchID
                
                // 저장 성공 후 초기화
                self.parseResult = nil
                self.previewRecords = []
            } catch {
                self.errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}
