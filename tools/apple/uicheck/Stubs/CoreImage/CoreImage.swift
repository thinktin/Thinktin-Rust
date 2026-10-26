// 配对二维码（14.8）的桩：签名照 macOS 14 SDK，只放用到的。
@_exported import CoreGraphics

open class CIImage: @unchecked Sendable {
    public var extent: CGRect { .zero }
    open func transformed(by matrix: CGAffineTransform) -> CIImage { self }
}

open class CIFilter {
    public init?(name: String, parameters params: [String: Any]?) {}
    open var outputImage: CIImage? { nil }
}

open class CIContext {
    public init(options: [String: Any]? = nil) {}
    open func createCGImage(_ image: CIImage, from fromRect: CGRect) -> CGImage? { nil }
}
