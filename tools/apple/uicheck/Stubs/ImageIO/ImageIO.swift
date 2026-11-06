@_exported import CoreGraphics

// ImageIO 的桩（第 1 轮 D 线：产出物库的图片缩略图、图片全屏查看，按需缩小解码）。签名照 iOS 17 / macOS 14 SDK。
// SDK 里 `CFData` 是 CoreFoundation 的类型，`Data as CFData` 能桥接；这里直接当 `Data`，写法一样。

public typealias CFData = Data

public final class CGImageSource {}

public func CGImageSourceCreateWithData(_ data: CFData, _ options: CFDictionary?) -> CGImageSource? { nil }

public func CGImageSourceCreateThumbnailAtIndex(
    _ isrc: CGImageSource, _ index: Int, _ options: CFDictionary?
) -> CGImage? { nil }

public func CGImageSourceCreateImageAtIndex(_ isrc: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    nil
}

public let kCGImageSourceCreateThumbnailFromImageAlways: CFString = "kCGImageSourceCreateThumbnailFromImageAlways"
public let kCGImageSourceCreateThumbnailWithTransform: CFString = "kCGImageSourceCreateThumbnailWithTransform"
public let kCGImageSourceThumbnailMaxPixelSize: CFString = "kCGImageSourceThumbnailMaxPixelSize"
public let kCGImageSourceShouldCacheImmediately: CFString = "kCGImageSourceShouldCacheImmediately"
