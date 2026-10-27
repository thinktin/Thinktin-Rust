// 辅助功能权限（14.7）的桩：签名照 macOS 14 SDK（HIServices 的 AXUIElement.h）。SDK 里这个框架连带导出 CoreGraphics。
@_exported import CoreGraphics

public func AXIsProcessTrusted() -> Bool { false }
public func AXIsProcessTrustedWithOptions(_ options: CFDictionary?) -> Bool { false }
