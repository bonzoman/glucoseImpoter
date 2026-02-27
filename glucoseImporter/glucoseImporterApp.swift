//
//  glucoseImporterApp.swift
//  glucoseImporter
//
//  Created by 오승준 on 2/20/26.
//

import SwiftUI
import AppTrackingTransparency

@main
struct glucoseImporterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    requestTrackingAuthorization()
                }
        }
    }
    
    private func requestTrackingAuthorization() {
        // 약간의 지연을 주어 앱 UI가 로드된 후 팝업이 뜨도록 함
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ATTrackingManager.requestTrackingAuthorization { status in
                switch status {
                case .authorized:
                    print("✅ ATT Authorized")
                case .denied:
                    print("❌ ATT Denied")
                case .notDetermined:
                    print("❓ ATT Not Determined")
                case .restricted:
                    print("🚫 ATT Restricted")
                @unknown default:
                    break
                }
            }
        }
    }
}
