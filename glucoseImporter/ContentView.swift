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
    @AppStorage("lastImportBatchID") private var lastImportBatchID: String = ""
    
    // 권한 및 파일 임포터 State
    @State private var isHealthKitAuthorized = false
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 상단 프라이버시 알림 영역
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.green)
                    Text("모든 데이터는 서버 등 외부로 전송되지 않고 기기 내에서만 안전하게 처리됩니다.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                
                List {
                    Section(header: Text("데이터 가져오기")) {
                        Button(action: {
                            showFileImporter = true
                        }) {
                            HStack {
                                Image(systemName: "doc.badge.plus")
                                Text("CSV 파일 선택 및 업로드")
                                    .fontWeight(.medium)
                            }
                        }
                        .disabled(!isHealthKitAuthorized)
                    }
                    
                    Section(header: Text("데이터 관리")) {
                        if !lastImportBatchID.isEmpty {
                            Button(role: .destructive, action: {
                                rollbackLastImport()
                            }) {
                                HStack {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                    Text("방금 전 업로드한 데이터 일괄 삭제")
                                }
                            }
                            .disabled(!isHealthKitAuthorized)
                        }
                        
                        Button(role: .destructive, action: {
                            showDatePicker = true
                        }) {
                            HStack {
                                Image(systemName: "calendar.badge.minus")
                                Text("과거 기록 삭제 (기간 지정)")
                            }
                        }
                        .disabled(!isHealthKitAuthorized)
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
                        DatePicker("시작일", selection: $deleteStartDate, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("종료일", selection: $deleteEndDate, displayedComponents: [.date, .hourAndMinute])
                    }
                    .navigationTitle("삭제할 기간 선택")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("취소") { showDatePicker = false }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("삭제 실행", role: .destructive) {
                                deleteByDateRange()
                                showDatePicker = false
                            }
                            .foregroundColor(.red)
                        }
                    }
                }
            }
            .onChange(of: csvViewModel.lastSavedBatchID) { _, newValue in
                if let batchID = newValue {
                    lastImportBatchID = batchID
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
        Task {
            do {
                let deletedCount = try await HealthKitStoreManager.shared.rollbackBatch(batchID: lastImportBatchID)
                print("🗑️ 롤백 성공: \(deletedCount)건 삭제됨")
                lastImportBatchID = "" // 롤백 후 비움
            } catch {
                print("❌ 롤백 실패: \(error.localizedDescription)")
            }
        }
    }
    
    private func deleteByDateRange() {
        Task {
            do {
                let deletedCount = try await HealthKitStoreManager.shared.deleteRecords(from: deleteStartDate, to: deleteEndDate)
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
