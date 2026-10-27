// Vision 的桩（12.9 扫配对二维码用到的条码种类）。
@_exported import Foundation

public struct VNBarcodeSymbology: Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let qr = VNBarcodeSymbology(rawValue: "VNBarcodeSymbologyQR")
}
