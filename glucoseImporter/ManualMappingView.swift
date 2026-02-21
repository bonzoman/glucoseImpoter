import SwiftUI

public struct ManualMappingView: View {
    @ObservedObject var viewModel: CSVImportViewModel
    @State private var dateColumnIndexStr: String = "0"
    @State private var valueColumnIndexStr: String = "1"
    @State private var dateFormatStr: String = "yyyy-MM-dd HH:mm"
    
    public init(viewModel: CSVImportViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        Form {
            Section(header: Text("알 수 없는 포맷 감지됨")) {
                Text("파일 상단의 컬럼 인덱스를 확인해 날짜와 혈당 값의 위치를 입력해주세요. 첫번째 열이 0번입니다.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("파일 미리보기 (상위 5줄)")) {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.manualMappingPreviewLines, id: \.self) { line in
                            Text(line)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            
            Section(header: Text("컬럼 인덱스 매핑 (0부터 시작)")) {
                HStack {
                    Text("날짜 컬럼 인덱스")
                    Spacer()
                    TextField("0", text: $dateColumnIndexStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)
                }
                
                HStack {
                    Text("혈당값 컬럼 인덱스")
                    Spacer()
                    TextField("1", text: $valueColumnIndexStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)
                }
            }
            
            Section(header: Text("날짜 포맷"), footer: Text("예: yyyy.MM.dd HH:mm, yyyy-MM-dd HH:mm:ss 등")) {
                TextField("yyyy-MM-dd HH:mm", text: $dateFormatStr)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            
            Button(action: {
                if let dIndex = Int(dateColumnIndexStr), let vIndex = Int(valueColumnIndexStr) {
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
            .disabled(Int(dateColumnIndexStr) == nil || Int(valueColumnIndexStr) == nil || dateFormatStr.isEmpty || viewModel.isImporting)
        }
    }
}
