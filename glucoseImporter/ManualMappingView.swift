import SwiftUI

public struct ManualMappingView: View {
    @ObservedObject var viewModel: CSVImportViewModel
    
    enum ColumnType: String, CaseIterable {
        case none = "매핑 안함"
        case date = "측정 일시"
        case value = "혈당 수치"
    }
    
    @State private var columnSelections: [Int: ColumnType] = [:]
    @State private var dateFormatStr: String = "yyyy-MM-dd HH:mm"
    @State private var sampleColumns: [String] = []
    
    public init(viewModel: CSVImportViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        Form {
            Section(header: Text("알 수 없는 포맷 감지됨")) {
                Text("아래 데이터 미리보기를 확인하고, 올바른 데이터 컬럼 아래에서 '측정 일시'와 '혈당 수치'를 지정해 주세요.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("컬럼 위치 매핑 (실제 데이터 1행 기반)")) {
                if sampleColumns.isEmpty {
                    Text("데이터를 불러올 수 없습니다.")
                        .foregroundColor(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 20) {
                            ForEach(0..<sampleColumns.count, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("열 \(index)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    Text(sampleColumns[index])
                                        .font(.subheadline.monospaced())
                                        .padding()
                                        .frame(height: 60)
                                        .background(Color(UIColor.secondarySystemBackground))
                                        .cornerRadius(8)
                                        .lineLimit(2)
                                        .frame(width: 140, alignment: .leading)
                                    
                                    Picker("용도", selection: Binding(
                                        get: { self.columnSelections[index] ?? .none },
                                        set: { self.columnSelections[index] = $0 }
                                    )) {
                                        ForEach(ColumnType.allCases, id: \.self) { type in
                                            Text(type.rawValue).tag(type)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 140)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            
            Section(header: Text("날짜 포맷"), footer: Text("예: yyyy.MM.dd HH:mm, yyyy-MM-dd HH:mm:ss 등")) {
                TextField("yyyy-MM-dd HH:mm", text: $dateFormatStr)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            
            Button(action: {
                if let dIndex = columnSelections.first(where: { $0.value == .date })?.key,
                   let vIndex = columnSelections.first(where: { $0.value == .value })?.key {
                    let config = ManualCSVFormat(dateColumnIndex: dIndex, valueColumnIndex: vIndex, dateFormat: dateFormatStr)
                    viewModel.applyManualMapping(config: config)
                }
            }) {
                HStack {
                    Spacer()
                    if viewModel.isImporting {
                        ProgressView().progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Text("수동 포맷으로 파싱 재시도")
                            .bold()
                    }
                    Spacer()
                }
            }
            .disabled(!isValidSelection || dateFormatStr.isEmpty || viewModel.isImporting)
        }
        .onAppear {
            extractSampleColumns()
        }
    }
    
    private var isValidSelection: Bool {
        let dateCount = columnSelections.values.filter { $0 == .date }.count
        let valueCount = columnSelections.values.filter { $0 == .value }.count
        return dateCount == 1 && valueCount == 1
    }
    
    private func extractSampleColumns() {
        // 프리뷰 라인 중 데이터 컬럼이 가장 많거나, 콤마 구분이 존재하는 마지막 행을 기준으로 추출
        if let targetLine = viewModel.manualMappingPreviewLines.last(where: { $0.contains(",") }) ?? viewModel.manualMappingPreviewLines.last {
            sampleColumns = targetLine.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            
            // 초기 매핑 시도: 휴리스틱하게 인덱스를 추정해볼 수도 있지만, 일단 비워둠
            for i in 0..<sampleColumns.count {
                columnSelections[i] = .none
            }
        }
    }
}
