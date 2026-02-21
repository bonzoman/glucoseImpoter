import SwiftUI

public struct CSVPreviewView: View {
    @ObservedObject var viewModel: CSVImportViewModel
    
    @Environment(\.presentationMode) var presentationMode
    
    // 수동 매핑 UI용 State
    @State private var selectedDateIndex: Int = 0
    @State private var selectedValueIndex: Int = 1
    @State private var sampleColumns: [String] = []
    
    public init(viewModel: CSVImportViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack {
            if let result = viewModel.parseResult {
                List {
                    Section(header: Text("파일 정보")) {
                        HStack {
                            Text("파 일 명")
                            Spacer()
                            Text(viewModel.lastLoadedURL?.lastPathComponent ?? "알 수 없음")
                                .foregroundColor(.primary)
                        }
                        HStack {
                            Text("포맷 인식")
                            Spacer()
                            if result.vendor == .custom {
                                Text("알 수 없는 포맷")
                                    .foregroundColor(.red)
                            } else {
                                Text("\(result.vendor.rawValue) 파일입니다")
                                    .foregroundColor(.blue)
                                    .bold()
                            }
                        }
                        
                        if result.vendor != .custom || !result.validRecords.isEmpty {
                            HStack {
                                Text("총 검증 결과")
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("총 \(result.totalReadLines)건 (성공 \(result.validRecords.count)건 / skip \(result.skippedCount)건 / 오류 \(result.invalidRecords.count)건)")
                                        .foregroundColor(result.invalidRecords.isEmpty ? .secondary : .red)
                                    if result.skippedCount > 0 {
                                        Text("\(result.skippedCount)건 skip 처리됨 (사유: \(result.skippedReason ?? "알 수 없음"))")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                        }
                    }
                    
                    if result.vendor == .custom || viewModel.showManualMapping {
                        Section(header: Text("알 수 없는 포맷 감지됨")) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("아래 데이터 열(Column)을 데이터 타입에 맞게 매핑해 주세요.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if sampleColumns.isEmpty {
                                    Text("데이터를 불러올 수 없습니다.")
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("측정일시")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    HStack {
                                        Picker("", selection: $selectedDateIndex) {
                                            ForEach(0..<sampleColumns.count, id: \.self) { index in
                                                Text("열 \(index): \(sampleColumns[index])").tag(index)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        Spacer()
                                    }
                                    
                                    Text("혈당수치")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    HStack {
                                        Picker("", selection: $selectedValueIndex) {
                                            ForEach(0..<sampleColumns.count, id: \.self) { index in
                                                Text("열 \(index): \(sampleColumns[index])").tag(index)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        Spacer()
                                    }
                                }
                                
                                Button(action: {
                                    let config = ManualCSVFormat(dateColumnIndex: selectedDateIndex, valueColumnIndex: selectedValueIndex, dateFormat: nil)
                                    viewModel.applyManualMapping(config: config)
                                }) {
                                    HStack {
                                        Spacer()
                                        Text("수동 포맷으로 파싱 시도")
                                            .bold()
                                        Spacer()
                                    }
                                }
                                .padding(.vertical, 8)
                                .disabled(sampleColumns.isEmpty || viewModel.isImporting || selectedDateIndex == selectedValueIndex)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    
                    if result.vendor != .custom || !result.validRecords.isEmpty {
                        Section {
                            Picker("필터", selection: $viewModel.selectedTab) {
                                Text("성공 (\(result.validRecords.count))").tag(0)
                                Text("오류 (\(result.invalidRecords.count))").tag(1)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }
                        
                        if viewModel.selectedTab == 0 {
                            Section(header: Text("미리보기 (최대 100건)")) {
                                ScrollView(.horizontal, showsIndicators: true) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        // 헤더(Header) 행
                                        HStack(spacing: 16) {
                                            Text("측정 일시").frame(width: 160, alignment: .leading)
                                            Text("혈당 수치").frame(width: 80, alignment: .trailing)
                                            Text("단위").frame(width: 60, alignment: .leading)
                                        }
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        
                                        Divider()
                                        
                                        // 데이터 행
                                        ForEach(viewModel.previewRecords) { record in
                                            HStack(spacing: 16) {
                                                Text(formatDate(record.timestamp, with: viewModel.usedDateFormat))
                                                    .frame(width: 160, alignment: .leading)
                                                Text(String(format: "%.1f", record.value))
                                                    .bold()
                                                    .frame(width: 80, alignment: .trailing)
                                                Text("mg/dL")
                                                    .frame(width: 60, alignment: .leading)
                                                    .foregroundColor(.secondary)
                                            }
                                            .font(.subheadline)
                                            Divider()
                                        }
                                        
                                        if result.validRecords.count > 100 {
                                            Text("+ \(result.validRecords.count - 100)건이 더 있습니다.")
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                                .padding(.top, 4)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                            }
                        } else {
                            Section(header: Text("오류 내역")) {
                                if result.invalidRecords.isEmpty {
                                    Text("오류 없음")
                                        .foregroundColor(.secondary)
                                } else {
                                    ScrollView(.horizontal, showsIndicators: true) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            // 헤더(Header) 행
                                            HStack(spacing: 16) {
                                                Text("Line").frame(width: 50, alignment: .leading)
                                                Text("오류 사유").frame(width: 150, alignment: .leading)
                                                Text("원본 데이터").frame(width: 300, alignment: .leading)
                                            }
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            
                                            Divider()
                                            
                                            // 에러 행
                                            ForEach(result.invalidRecords.prefix(100)) { error in
                                                HStack(spacing: 16) {
                                                    Text("\(error.lineNumber)")
                                                        .frame(width: 50, alignment: .leading)
                                                        .foregroundColor(.secondary)
                                                    Text(error.reason)
                                                        .frame(width: 180, alignment: .leading)
                                                        .foregroundColor(.red)
                                                    Text(error.rawLine)
                                                        .frame(width: 400, alignment: .leading)
                                                        .foregroundColor(.secondary)
                                                }
                                                .font(.caption.monospaced())
                                                Divider()
                                            }
                                            
                                            if result.invalidRecords.count > 100 {
                                                Text("+ \(result.invalidRecords.count - 100)건의 오류가 더 있습니다.")
                                                    .font(.caption)
                                                    .foregroundColor(.blue)
                                                    .padding(.top, 4)
                                            }
                                        }
                                        .padding(.vertical, 8)
                                    }
                                }
                            }
                        }
                    }
                }
            } else if viewModel.isImporting {
                ProgressView("파일 읽는 중...")
            } else {
                Text("데이터가 없습니다.")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("업로드 미리보기")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if viewModel.isImporting {
                    ProgressView().progressViewStyle(CircularProgressViewStyle())
                }
            }
        }
        .onAppear {
            if !viewModel.isImporting {
                extractSampleColumns()
            }
        }
        .onChange(of: viewModel.isImporting) { isImporting in
            if !isImporting {
                extractSampleColumns()
            }
        }
        .alert("HealthKit에 데이터 저장", isPresented: $viewModel.showSaveConfirmation) {
            Button("취소", role: .cancel) { }
            Button("저장 실행") {
                viewModel.startHealthKitSave()
            }
        } message: {
            Text("검증이 통과된 \(viewModel.previewRecords.count)건의 데이터를 HealthKit에 덮어쓰기 권한으로 기록하시겠습니까?")
        }
        .alert("중복 데이터 발견", isPresented: $viewModel.showDuplicateAlert) {
            Button("기존 데이터 덮어쓰기", role: .destructive) {
                viewModel.saveToHealthKit(strategy: .overwrite)
            }
            Button("새로운 데이터만 추가") {
                viewModel.saveToHealthKit(strategy: .skip)
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("선택한 기간에 이미 저장된 혈당 데이터가 있습니다. 기존 데이터를 지우고 덮어쓰시겠습니까, 아니면 새로운 데이터만 추가로 저장하시겠습니까?")
        }
        .alert("저장 완료", isPresented: $viewModel.showSaveSuccessAlert) {
            Button("확인", role: .cancel) { 
                presentationMode.wrappedValue.dismiss()
            }
        } message: {
            Text("\(viewModel.lastSavedCount)건의 데이터가 안전하게 저장되었습니다.")
        }
        .alert(
            "오류 발생",
            isPresented: Binding<Bool>(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
            }
        }
    }
    
    private func extractSampleColumns() {
        if let lines = viewModel.parseResult?.invalidRecords.prefix(5).map({ $0.rawLine }), let targetLine = lines.last(where: { $0.contains(",") }) ?? lines.last {
            sampleColumns = targetLine.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if sampleColumns.count > 0 { selectedDateIndex = 0 }
            if sampleColumns.count > 1 { selectedValueIndex = 1 }
        } else if let firstValid = viewModel.parseResult?.validRecords.first {
            // 이 곳은 도달할 가능성 적음
            sampleColumns = ["날짜", "수치"]
        }
    }
    
    private func formatDate(_ date: Date, with formatString: String?) -> String {
        guard let format = formatString else {
            return date.formatted()
        }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
