import Foundation

/// 截图和点击的坐标换算（WBS 14.3、14.4）：`computer_click` 的坐标是最近一张 `computer_screenshot` 的像素。
///
/// 截的是主显示器。图按显示器的点数乘缩放比例算像素，长边超过 `maxLongEdge` 时等比缩小（模型看大图也会先缩小，
/// 传原图只是浪费流量）；点击时按同样的比例换回全局坐标（点，左上角原点，`CGEvent` 用的坐标）。
public struct ScreenshotGeometry: Hashable, Sendable {
    /// 模型看图的长边上限（像素）。
    public static let maxLongEdge = 1568

    /// 截的那块屏幕在全局坐标里的位置（点）。
    public var displayFrame: CGRect
    public var imageWidth: Int
    public var imageHeight: Int

    /// - Parameters:
    ///   - displayFrame: 显示器的位置和大小（点）。
    ///   - scale: 每个点几个像素（Retina 是 2）。
    public init(displayFrame: CGRect, scale: CGFloat, maxLongEdge: Int = ScreenshotGeometry.maxLongEdge) {
        self.displayFrame = displayFrame
        let width = max(1, displayFrame.width * max(scale, 1))
        let height = max(1, displayFrame.height * max(scale, 1))
        let shrink = min(1, CGFloat(maxLongEdge) / max(width, height))
        imageWidth = max(1, Int((width * shrink).rounded()))
        imageHeight = max(1, Int((height * shrink).rounded()))
    }

    /// 图上的像素换成全局坐标（像素的中心）；不在图里时是 nil。
    public func point(x: Int, y: Int) -> CGPoint? {
        guard (0..<imageWidth).contains(x), (0..<imageHeight).contains(y) else { return nil }
        let sx = displayFrame.width / CGFloat(imageWidth)
        let sy = displayFrame.height / CGFloat(imageHeight)
        return CGPoint(
            x: displayFrame.minX + (CGFloat(x) + 0.5) * sx,
            y: displayFrame.minY + (CGFloat(y) + 0.5) * sy)
    }
}
