import SwiftUI

public struct ManualMappingView: View {
    @ObservedObject var viewModel: CSVImportViewModel
    
    @State private var selectedDateIndex: Int = 0
    @State private var selectedValueIndex: Int = 1
    @State private var sampleColumns: [String] = []
    
    public init(viewModel: CSVImportViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        Form {
            Section(header: Text("알 수 없는 포맷 감지됨")) {
                Text("아래 데이터 미리보기를 확인하고, 해당하는 열을 선택해 주세요.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("컬럼 위치 매핑 (실제 데이터 1행 기반)")) {
                if sampleColumns.isEmpty {
                    Text("데이터를 불러올 수 없습니다.")
                        .foregroundColor(.secondary)
                } else {
                    Picker("측정 일시가 있는 열", selection: $selectedDateIndex) {
                        ForEach(0..<sampleColumns.count, id: \.self) { index in
                            Text("열 \(index): \(sampleColumns[index])").tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Picker("혈당 수치가 있는 열", selection: $selectedValueIndex) {
                        ForEach(0..<sampleColumns.count, id: \.self) { index in
                            Text("열 \(index): \(sampleColumns[index])").tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            
            Button(action: {
                // dateFormat은 옵셔널로 nil 전달하여 자동 인식 유도
                let config = ManualCSVFormat(dateColumnIndex: selectedDateIndex, valueColumnIndex: selectedValueIndex, dateFormat: nil)
                viewModel.applyManualMapping(config: config)
            }) {
                HStack {
                    Spacer()
                    if viewModel.isImporting {
                        ProgressView().progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Text("수동 포맷으로 파싱 시도")
                            .bold()
                    }
                    Spacer()
                }
            }
            .disabled(sampleColumns.isEmpty || viewModel.isImporting || selectedDateIndex == selectedValueIndex)
        }
        .onAppear {
            extractSampleColumns()
        }
    }
    
    private func extractSampleColumns() {
        // 프리뷰 라인 중 데이터 컬럼이 가장 많거나, 콤마 구분이 존재하는 마지막 행을 기준으로 추출
        if let targetLine = viewModel.manualMappingPreviewLines.last(where: { $0.contains(",") }) ?? viewModel.manualMappingPreviewLines.last {
            sampleColumns = targetLine.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            
            // 초기값 세팅
            if sampleColumns.count > 0 { selectedDateIndex = 0 }
            if sampleColumns.count > 1 { selectedValueIndex = 1 }
        }
    }
}
