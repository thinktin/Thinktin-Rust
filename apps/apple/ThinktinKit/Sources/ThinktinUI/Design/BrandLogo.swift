import SwiftUI

/// ThinkTin 的标志（Logo G1.0，`docs/brand/logo`）：罐体三条线加一条彩色双圈线，用 SwiftUI 原生矢量画，多大都清楚。
///
/// 几何在 `BrandLogo+Geometry.swift`，由 `tools/apple/brand_assets.py` 从 Logo 的几何参数生成（圆弧转三次贝塞尔，和原稿
/// 逐像素一致），改 Logo 后重跑脚本，不要手改。按线条的外缘等比缩放，不带原稿那一圈白边；用 `.frame(height:)` 定大小。
/// 罐体线条用 `Theme.ink`，深色模式自动变浅；双圈线用原稿的渐变（`.color`）或同一种墨色（`.monochrome`）。
public struct BrandLogo: View {
    public enum Style: Sendable {
        /// 双圈线是彩色渐变（默认）。
        case color
        /// 全部用墨色：小图标、单色场合。
        case monochrome
    }

    private let style: Style

    public init(style: Style = .color) {
        self.style = style
    }

    public var body: some View {
        GeometryReader { proxy in
            let scale = Self.scale(for: proxy.size)
            ZStack {
                BrandLogoShape(part: .body).stroke(Theme.ink, style: Self.stroke(Self.bodyWidth * scale))
                BrandLogoShape(part: .rim).stroke(Theme.ink, style: Self.stroke(Self.rimWidth * scale))
                BrandLogoShape(part: .innerRim).stroke(Theme.ink, style: Self.stroke(Self.innerRimWidth * scale))
                switch style {
                case .color:
                    BrandLogoShape(part: .loop).stroke(Self.gradient, style: Self.stroke(Self.loopWidth * scale))
                case .monochrome:
                    BrandLogoShape(part: .loop).stroke(Theme.ink, style: Self.stroke(Self.loopWidth * scale))
                }
            }
        }
        .aspectRatio(Self.contentBounds.width / Self.contentBounds.height, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "ThinkTin"))
        .accessibilityAddTraits(.isImage)
    }

    /// 画板单位到视图点的比例：内容区等比放进给定的大小。
    static func scale(for size: CGSize) -> CGFloat {
        min(size.width / contentBounds.width, size.height / contentBounds.height)
    }

    /// 原稿的线条：圆头、圆角连接。
    static func stroke(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    /// 双圈线的渐变：原稿是按画板坐标（userSpaceOnUse）的线性渐变，这里换算成内容区里的相对位置。
    /// 视图按内容区的宽高比显示，所以和原稿一致；渐变轴外按端点色延展（SwiftUI 的默认行为）。
    static var gradient: LinearGradient {
        LinearGradient(
            stops: gradientStops.map { stop in
                let color = HexColor(stop.hex)
                return Gradient.Stop(
                    color: Color(red: color.red, green: color.green, blue: color.blue), location: stop.location)
            },
            startPoint: unitPoint(gradientStart),
            endPoint: unitPoint(gradientEnd)
        )
    }

    static func unitPoint(_ point: CGPoint) -> UnitPoint {
        UnitPoint(
            x: (point.x - contentBounds.minX) / contentBounds.width,
            y: (point.y - contentBounds.minY) / contentBounds.height
        )
    }
}

/// Logo 的一条路径：画板坐标等比、居中地映射进给定的矩形。
struct BrandLogoShape: Shape {
    enum Part: Sendable {
        case body, rim, innerRim, loop
    }

    let part: Part

    func path(in rect: CGRect) -> Path {
        let bounds = BrandLogo.contentBounds
        let scale = BrandLogo.scale(for: rect.size)
        let origin = CGPoint(
            x: rect.midX - (bounds.midX * scale),
            y: rect.midY - (bounds.midY * scale)
        )
        var builder = BrandLogoPathBuilder(scale: scale, origin: origin)
        switch part {
        case .body: BrandLogo.bodyPath(&builder)
        case .rim: BrandLogo.rimPath(&builder)
        case .innerRim: BrandLogo.innerRimPath(&builder)
        case .loop: BrandLogo.loopPath(&builder)
        }
        return builder.path
    }
}

/// 生成的几何代码用它画路径：坐标是画板单位，在这里换成视图的点。
struct BrandLogoPathBuilder {
    private(set) var path = Path()
    let scale: CGFloat
    let origin: CGPoint

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }

    mutating func move(_ x: CGFloat, _ y: CGFloat) {
        path.move(to: point(x, y))
    }

    mutating func line(_ x: CGFloat, _ y: CGFloat) {
        path.addLine(to: point(x, y))
    }

    /// 三次贝塞尔：终点 (x, y)，两个控制点。
    mutating func curve(
        _ x: CGFloat, _ y: CGFloat, _ control1X: CGFloat, _ control1Y: CGFloat, _ control2X: CGFloat,
        _ control2Y: CGFloat
    ) {
        path.addCurve(to: point(x, y), control1: point(control1X, control1Y), control2: point(control2X, control2Y))
    }

    mutating func close() {
        path.closeSubpath()
    }
}

#Preview("Logo · 浅色") {
    HStack(alignment: .bottom, spacing: Metrics.Spacing.l) {
        BrandLogo().frame(height: 160)
        BrandLogo().frame(height: 64)
        BrandLogo().frame(height: 28)
        BrandLogo(style: .monochrome).frame(height: 64)
    }
    .padding()
    .background(Theme.paper)
}

#Preview("Logo · 深色") {
    HStack(alignment: .bottom, spacing: Metrics.Spacing.l) {
        BrandLogo().frame(height: 160)
        BrandLogo().frame(height: 28)
        BrandLogo(style: .monochrome).frame(height: 64)
    }
    .padding()
    .background(Theme.paper)
    .preferredColorScheme(.dark)
}
