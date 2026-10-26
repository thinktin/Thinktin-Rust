import SwiftUI
import ThinktinUI
import Vision
import VisionKit

/// 扫电脑上的配对二维码（WBS 12.9）：VisionKit 的 `DataScannerViewController`，只认 QR 码、只认
/// `thinktin-pair:` 开头的内容，扫到一个就停。设备不支持（模拟器、没有相机权限）时不提供，配对页只留粘贴配对码。
/// 相机权限的说明在 Info.plist 的 `NSCameraUsageDescription`。
struct PairingCodeScanner: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    /// 给界面用的（`\.pairingScanner`）；不能扫时为 nil。
    @MainActor static var environmentValue: PairingScanner? {
        guard isAvailable else { return nil }
        return PairingScanner { onCode in AnyView(PairingCodeScanner(onCode: onCode)) }
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: @MainActor (String) -> Void
        private var done = false

        init(onCode: @escaping @MainActor (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]
        ) {
            guard !done else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item, let value = barcode.payloadStringValue,
                    value.hasPrefix("thinktin-pair:")
                else { continue }
                done = true
                dataScanner.stopScanning()
                onCode(value)
                return
            }
        }
    }
}
