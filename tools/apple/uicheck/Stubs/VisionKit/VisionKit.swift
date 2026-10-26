// VisionKit 的桩（12.9 扫配对二维码）：签名照 iOS 17 SDK，只放用到的。
@_exported import Foundation
import UIKit
import Vision

@MainActor
open class DataScannerViewController: UIViewController {
    public struct RecognizedDataType: Hashable, Sendable {
        let symbologies: [VNBarcodeSymbology]
        public static func barcode(symbologies: [VNBarcodeSymbology] = []) -> RecognizedDataType {
            RecognizedDataType(symbologies: symbologies)
        }
    }

    public enum QualityLevel: Sendable {
        case balanced, fast, accurate
    }

    public static var isSupported: Bool { false }
    public static var isAvailable: Bool { false }

    open weak var delegate: (any DataScannerViewControllerDelegate)?

    public init(
        recognizedDataTypes: Set<RecognizedDataType>, qualityLevel: QualityLevel = .balanced,
        recognizesMultipleItems: Bool = false, isHighFrameRateTrackingEnabled: Bool = true,
        isPinchToZoomEnabled: Bool = true, isGuidanceEnabled: Bool = true, isHighlightingEnabled: Bool = false
    ) {
        super.init()
    }

    open func startScanning() throws {}
    open func stopScanning() {}
}

public enum RecognizedItem: Sendable {
    public struct Barcode: Sendable {
        public var payloadStringValue: String? { nil }
    }

    public struct Text: Sendable {
        public var transcript: String { "" }
    }

    case text(Text)
    case barcode(Barcode)
}

@MainActor
public protocol DataScannerViewControllerDelegate: AnyObject {
    func dataScanner(
        _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem])
}

extension DataScannerViewControllerDelegate {
    public func dataScanner(
        _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]
    ) {}
}
