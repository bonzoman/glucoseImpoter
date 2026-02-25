//
//  ContentView.swift
//  glucoseImporter
//
//  Created by 오승준 on 2/20/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var csvViewModel = CSVImportViewModel()
    @State private var showPreview = false
    
    // 삭제 관련 State
    @State private var deleteStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var deleteEndDate = Date()
    @State private var showDatePicker = false
    @State private var deleteTargetCount: Int? = nil
    @State private var isFetchingDeleteCount = false
    @State private var showDeleteConfirm = false
    @State private var showNoDataAlert = false
    @AppStorage("lastImportBatchID") private var lastImportBatchID: String = ""
    @AppStorage("lastImportCount") private var lastImportCount: Int = 0
    @State private var isRollingBack = false
    
    // 권한 및 파일 임포터 State
    @State private var isHealthKitAuthorized = false
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 상단 프라이버시 알림 영역 (고정)
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 18))
                        Text("모든 데이터는 서버 등 외부로 전송되지 않고 기기 내에서만 안전하게 처리됩니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    
                    ScrollView {
                        VStack(spacing: 24) {
                            
                            // 1. 메인 기능: CSV 업로드 (Hero Card)
                            Button(action: {
                                showFileImporter = true
                            }) {
                                VStack(spacing: 16) {
                                    Image(systemName: "doc.badge.plus")
                                        .font(.system(size: 48, weight: .regular))
                                    
                                    VStack(spacing: 4) {
                                        Text("CSV 파일 선택 및 업로드")
                                            .font(.title3)
                                            .fontWeight(.bold)
                                        
                                        Text("파일을 선택하면 자동으로 포맷을 인식합니다.")
                                            .font(.footnote)
                                            .opacity(0.8)
                                    }
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                                .padding(.horizontal, 20)
                                .background(
                                    LinearGradient(gradient: Gradient(colors: [Color.blue, Color.teal]), startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .cornerRadius(20)
                                .shadow(color: Color.teal.opacity(0.3), radius: 10, x: 0, y: 5)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(!isHealthKitAuthorized)
                            .opacity(isHealthKitAuthorized ? 1.0 : 0.6)
                            .padding(.top, 24)
                            
                            // 2. 롤백(최근 동기화 n건) Floating Card
                            if !lastImportBatchID.isEmpty {
                                HStack {
                                    Button(action: {
                                        rollbackLastImport()
                                    }) {
                                        HStack {
                                            if isRollingBack {
                                                ProgressView()
                                                    .progressViewStyle(CircularProgressViewStyle())
                                                    .padding(.trailing, 4)
                                                Text("삭제 진행 중...")
                                                    .font(.subheadline)
                                                    .foregroundColor(.red)
                                            } else {
                                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                                    .foregroundColor(.red)
                                                    .font(.system(size: 20))
                                                Text("최근 업로드 \(lastImportCount)건 일괄 삭제")
                                                    .font(.subheadline)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(.red)
                                            }
                                        }
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 16)
                                    }
                                    .disabled(!isHealthKitAuthorized || isRollingBack)
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        // 수동 닫기: 롤백 기능 숨김
                                        lastImportBatchID = ""
                                        lastImportCount = 0
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(Color(UIColor.tertiaryLabel))
                                            .font(.system(size: 20))
                                    }
                                    .padding(.trailing, 16)
                                }
                                .background(Color(UIColor.secondarySystemGroupedBackground))
                                .cornerRadius(12)
                                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                            }
                            
                            Spacer(minLength: 40)
                            
                            // 3. 과거 기록 삭제 (보조 텍스트 버튼으로 축소)
                            Button(action: {
                                deleteTargetCount = nil
                                showDatePicker = true
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "trash")
                                    Text("과거 데이터 수동 삭제 (기간 지정)")
                                }
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                            }
                            .disabled(!isHealthKitAuthorized)
                            
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Glucose Importer")
            .task {
                do {
                    try await HealthKitStoreManager.shared.requestAuthorization()
                    isHealthKitAuthorized = true
                    print("✅ HealthKit 권한 획득 성공")
                } catch {
                    isHealthKitAuthorized = false
                    print("⚠️ HealthKit 권한 획득 실패: \(error.localizedDescription)")
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType.commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    // 보안 URL 접근 권한 획득
                    guard url.startAccessingSecurityScopedResource() else { return }
                    
                    // 비동기 파싱 중 권한이 만료되는 것을 방지하기 위해 임시 폴더로 파일 복사
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                    do {
                        if FileManager.default.fileExists(atPath: tempURL.path) {
                            try FileManager.default.removeItem(at: tempURL)
                        }
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        url.stopAccessingSecurityScopedResource()
                        
                        // 단일 로딩 함수 호출
                        csvViewModel.loadCSV(from: tempURL)
                        
                        showPreview = true
                    } catch {
                        url.stopAccessingSecurityScopedResource()
                        print("파일 복사 실패: \(error.localizedDescription)")
                    }
                case .failure(let error):
                    print("파일 선택 실패: \(error.localizedDescription)")
                }
            }
            .sheet(isPresented: $showPreview) {
                NavigationView {
                    CSVPreviewView(viewModel: csvViewModel)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("취소") {
                                    showPreview = false
                                }
                            }
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("HealthKit 저장") {
                                    csvViewModel.requestSave()
                                }
                                .disabled((csvViewModel.parseResult?.validRecords.isEmpty ?? true))
                            }
                        }
                }
            }
            .sheet(isPresented: $showDatePicker) {
                NavigationView {
                    Form {
                        Section(header: Text("안내")) {
                            Text("이 앱(Glucose Importer)을 통해 넣은 데이터만 삭제 대상이 됩니다.\n다른 앱에서 기록한 타사 데이터는 절대로 삭제되지 않습니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Section(header: Text("기간 설정 (일자 기준)")) {
                            DatePicker("시작일", selection: $deleteStartDate, displayedComponents: [.date])
                                .environment(\.locale, Locale(identifier: "en_US"))
                            DatePicker("종료일", selection: $deleteEndDate, displayedComponents: [.date])
                                .environment(\.locale, Locale(identifier: "en_US"))
                        }
                        
                        if isFetchingDeleteCount {
                            Section {
                                HStack {
                                    Spacer()
                                    ProgressView("삭제 대상 검색 중...")
                                        .progressViewStyle(CircularProgressViewStyle())
                                    Spacer()
                                }
                            }
                        } else {
                            Section {
                                Button(action: {
                                    fetchTargetCount()
                                }) {
                                    HStack {
                                        Spacer()
                                        Text("삭제 대상 조회")
                                            .fontWeight(.bold)
                                        Spacer()
                                    }
                                }
                                
                                if let count = deleteTargetCount {
                                    if count == 0 {
                                        Text("해당 기간 내에 이 앱으로 저장된 데이터가 존재하지 않습니다.")
                                            .foregroundColor(.secondary)
                                            .font(.subheadline)
                                            .frame(maxWidth: .infinity, alignment: .center)
                                            .multilineTextAlignment(.center)
                                    } else {
                                        Text("\(count)건의 삭제 대상이 존재합니다.")
                                            .foregroundColor(.red)
                                            .font(.subheadline)
                                            .frame(maxWidth: .infinity, alignment: .center)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("기록 삭제")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("취소") { showDatePicker = false }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            if let count = deleteTargetCount, count > 0, !isFetchingDeleteCount {
                                Button("삭제 실행") {
                                    showDeleteConfirm = true
                                }
                                .foregroundColor(.red)
                            }
                        }
                    }
                    .alert("정말 삭제하시겠습니까?", isPresented: $showDeleteConfirm) {
                        Button("취소", role: .cancel) { }
                        Button("삭제", role: .destructive) {
                            deleteByDateRange()
                            showDatePicker = false
                        }
                    } message: {
                        Text("\(deleteTargetCount ?? 0)건의 데이터가 HealthKit에서 영구적으로 삭제됩니다. 계속하시겠습니까?")
                    }
                }
            }
            .onChange(of: csvViewModel.lastSavedBatchID) { _, newValue in
                if let batchID = newValue {
                    lastImportBatchID = batchID
                    lastImportCount = csvViewModel.lastSavedCount
                }
            }
            .onChange(of: csvViewModel.parseResult) { _, newResult in
                // 저장 완료 후 결과가 초기화되면 모달 닫기
                if newResult == nil && !csvViewModel.isImporting {
                    showPreview = false
                }
            }
        }
    }

    private func rollbackLastImport() {
        guard !lastImportBatchID.isEmpty else { return }
        isRollingBack = true
        Task {
            do {
                let deletedCount = try await HealthKitStoreManager.shared.rollbackBatch(batchID: lastImportBatchID)
                print("🗑️ 롤백 성공: \(deletedCount)건 삭제됨")
                await MainActor.run {
                    lastImportBatchID = "" // 롤백 후 리스트에서 비움
                    lastImportCount = 0
                    isRollingBack = false
                }
            } catch {
                print("❌ 롤백 실패: \(error.localizedDescription)")
                await MainActor.run {
                    isRollingBack = false
                }
            }
        }
    }
    
    private func fetchTargetCount() {
        isFetchingDeleteCount = true
        deleteTargetCount = nil
        // 시작일은 0시 0분, 종료일은 23시 59분으로 보정
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: deleteStartDate)
        var endComp = calendar.dateComponents([.year, .month, .day], from: deleteEndDate)
        endComp.hour = 23
        endComp.minute = 59
        endComp.second = 59
        let end = calendar.date(from: endComp) ?? deleteEndDate
        
        Task {
            do {
                let count = try await HealthKitStoreManager.shared.fetchDeleteTargetCount(from: start, to: end)
                await MainActor.run {
                    self.deleteTargetCount = count
                    self.isFetchingDeleteCount = false
                }
            } catch {
                await MainActor.run {
                    self.isFetchingDeleteCount = false
                    print("❌ 삭제 카운트 조회 실패: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func deleteByDateRange() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: deleteStartDate)
        var endComp = calendar.dateComponents([.year, .month, .day], from: deleteEndDate)
        endComp.hour = 23
        endComp.minute = 59
        endComp.second = 59
        let end = calendar.date(from: endComp) ?? deleteEndDate
        
        Task {
            do {
                let deletedCount = try await HealthKitStoreManager.shared.deleteRecords(from: start, to: end)
                print("🗑️ 기간 삭제 성공: \(deletedCount)건 삭제됨")
            } catch {
                print("❌ 기간 삭제 실패: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    ContentView()
}
