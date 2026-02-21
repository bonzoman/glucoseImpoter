import SwiftUI
import Combine

@MainActor
public final class CSVImportViewModel: ObservableObject {
    @Published public var parseResult: CSVParseResult? = nil
    @Published public var isImporting = false
    @Published var isLoading: Bool = false
    @Published public var errorMessage: String? = nil
    
    // 포맷/건수 정보
    @Published var usedDateFormat: String? = nil
    @Published var detectedVendor: CSVVendorType? = nil
    @Published var validRecords: [GlucoseRecord] = []
    @Published var invalidRecords: [CSVParseErrorRecord] = []
    
    var totalRecordsCount: Int {
        return validRecords.count + invalidRecords.count
    }
    
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
    
    // 수동 매핑 상태
    @Published public var showManualMapping = false
    public var lastLoadedURL: URL? = nil
    
    // 저장 성공 상태 
    @Published public var showSaveSuccessAlert = false
    @Published public var lastSavedCount = 0
    
    public init() {}
    
    public func loadCSV(from url: URL) {
        lastLoadedURL = url
        Task {
            isImporting = true
            errorMessage = nil
            do {
                let reader = GlucoseCSVReader()
                let result = try await reader.read(from: url, targetUnit: .mgDL)
                
                await MainActor.run {
                    self.parseResult = result
                    self.detectedVendor = result.vendor
                    self.validRecords = result.validRecords
                    self.invalidRecords = result.invalidRecords
                    self.usedDateFormat = result.usedDateFormat
                    self.isLoading = false
                    
                    // 미리보기는 최대 100건까지만 노출
                    self.previewRecords = Array(result.validRecords.prefix(100))
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
    
    public func applyManualMapping(config: ManualCSVFormat) {
        guard let url = lastLoadedURL else { return }
        Task {
            isImporting = true
            errorMessage = nil
            do {
                let reader = GlucoseCSVReader()
                let result = try await reader.read(from: url, targetUnit: .mgDL, manualConfig: config)
                
                await MainActor.run {
                    self.parseResult = result
                    self.detectedVendor = result.vendor
                    self.validRecords = result.validRecords
                    self.invalidRecords = result.invalidRecords
                    self.usedDateFormat = result.usedDateFormat
                    self.isLoading = false
                    
                    self.previewRecords = Array(result.validRecords.prefix(100))
                    self.showManualMapping = false
                    
                    if result.validRecords.isEmpty {
                        self.errorMessage = "파싱 가능한 정상 데이터가 0건입니다. 매핑 열을 잘못 지정했거나 파일 내용에 문제가 없는지(숫자 필드 등) 다시 확인해주세요."
                    }
                }
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
                
                // 저장 성공 후 UI 및 상태 데이터 업데이트
                self.lastSavedBatchID = batchID
                self.lastSavedCount = savedCount
                self.showSaveSuccessAlert = true
            } catch {
                self.errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}
