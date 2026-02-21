import SwiftUI

public struct CSVPreviewView: View {
    @ObservedObject var viewModel: CSVImportViewModel
    
    public init(viewModel: CSVImportViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack {
            if let result = viewModel.parseResult {
                List {
                    Section(header: Text("파일 정보")) {
                        HStack {
                            Text("포맷 인식")
                            Spacer()
                            if result.vendor == .custom {
                                Text("알 수 없는 포맷 (추후 수동 매핑)")
                                    .foregroundColor(.red)
                            } else {
                                Text("\(result.vendor.rawValue) 파일입니다")
                                    .foregroundColor(.blue)
                                    .bold()
                            }
                        }
                        HStack {
                            Text("총 검증 결과")
                            Spacer()
                            Text("성공 \(result.validRecords.count)건 / 오류 \(result.invalidRecords.count)건")
                                .foregroundColor(result.invalidRecords.isEmpty ? .secondary : .red)
                        }
                    }
                    
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
                                            Text("\(record.timestamp.formatted())")
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
                                                    .frame(width: 150, alignment: .leading)
                                                    .foregroundColor(.red)
                                                Text(error.rawLine)
                                                    .frame(width: 300, alignment: .leading)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                            .font(.caption)
                                            Divider()
                                        }
                                    }
                                    .padding(.vertical, 8)
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
        .confirmationDialog("HealthKit에 데이터 100건을 저장하시겠습니까?", isPresented: $viewModel.showSaveConfirmation, titleVisibility: .visible) {
            Button("저장 실행") {
                viewModel.startHealthKitSave()
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("검증이 통과된 \(viewModel.previewRecords.count)건의 데이터가 HealthKit에 덮어쓰기 권한으로 기록됩니다.")
        }
        .alert(isPresented: $viewModel.showDuplicateAlert) {
            Alert(
                title: Text("중복 데이터 발견"),
                message: Text("선택한 기간에 이미 저장된 혈당 데이터가 있습니다. 기존 데이터를 지우고 덮어쓰시겠습니까, 아니면 새로운 데이터만 추가로 저장하시겠습니까?"),
                primaryButton: .destructive(Text("기존 데이터 덮어쓰기")) {
                    viewModel.saveToHealthKit(strategy: .overwrite)
                },
                secondaryButton: .default(Text("새로운 데이터만 추가(건너뛰기)")) {
                    viewModel.saveToHealthKit(strategy: .skip)
                }
            )
        }
    }
}
