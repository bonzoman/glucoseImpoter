import Foundation
let data = try! Data(contentsOf: URL(fileURLWithPath: "/Users/sjo/xcode/glucoseImporter/222test.csv"))
let eucKRString = String(data: data, encoding: String.Encoding(rawValue: 0x80000422))!
let lowerContent = eucKRString.lowercased()
print("Contains 기록:", lowerContent.contains("기록"))
print("Contains 장치:", lowerContent.contains("장치"))
print("Contains 혈당:", lowerContent.contains("혈당"))
print("Contains 시간:", lowerContent.contains("시간"))
print("Contains 모델:", lowerContent.contains("모델"))
