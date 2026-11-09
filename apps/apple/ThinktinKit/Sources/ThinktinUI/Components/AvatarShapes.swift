import Foundation
import SwiftUI
import ThinktinKit

// Botin 头像的 15 种形状（`AvatarShape`，规范 docs/ios-ui-redesign.md 4.4.4、4.7.1）：都是自己设计的简单几何、有机形状，
// 上面画两只眼睛（`BotinFace` 按这里的轮廓算出一圈半径来画身体，换形状时按半径变形；在跑、在等用户时会动）；不照搬
// 参考 App 的形象。引擎、模型厂商的首字图标也用这里的圆角方形（`AvatarGlyph`）。坐标在单位正方形里（0…1，y 向下），
// 画的时候等比、居中地放进给定的矩形。

/// 头像形状的路径：首字图标（`AvatarGlyph`）的底。Botin 的脸（`BotinFace`）不直接用它，用同一份轮廓
/// （`AvatarShapeGeometry`）算出的一圈半径。
struct AvatarShapePath: Shape {
    let shape: AvatarShape

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        var builder = AvatarPathBuilder(
            origin: CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2), side: side)
        AvatarShapeGeometry.draw(shape, into: &builder)
        return builder.path
    }
}

/// 首字放在形状的哪儿、多大（`AvatarGlyph`；现在只有引擎、厂商的圆角方形用，Botin 画脸）：三角形、星形这类重心偏下、
/// 中间窄的，字小一点、往下挪一点。
struct AvatarMonogramLayout: Hashable, Sendable {
    /// 字号是直径的几倍。
    var textScale: CGFloat
    /// 往下挪直径的几倍（负的往上）。
    var verticalOffset: CGFloat

    /// 首字最小的字号：窄的形状在小头像上（导航栏的 24pt）按比例算只有 6、7pt，汉字糊成一团；宁可字比形状中间略宽一点。
    static let minimumFontSize: CGFloat = 9
    /// 圆形的比例：小头像上字号最大到这里（不比圆形的字还大）。
    static let maximumTextScale: CGFloat = 0.42

    /// 边长 `side` 的头像上首字的字号：按形状的比例，不小于 `minimumFontSize`，也不超过圆形的比例。
    func fontSize(for side: CGFloat) -> CGFloat {
        min(max(side * textScale, Self.minimumFontSize), side * Self.maximumTextScale)
    }

    init(_ shape: AvatarShape) {
        switch shape {
        case .circle, .squircle, .hexagon, .octagon, .pebble, .scallop:
            self.init(textScale: Self.maximumTextScale, verticalOffset: 0)
        case .arch: self.init(textScale: 0.40, verticalOffset: 0.05)
        case .diamond: self.init(textScale: 0.32, verticalOffset: 0)
        case .triangle: self.init(textScale: 0.30, verticalOffset: 0.12)
        case .shield: self.init(textScale: 0.38, verticalOffset: -0.02)
        case .leaf: self.init(textScale: 0.32, verticalOffset: 0)
        case .sparkle: self.init(textScale: 0.26, verticalOffset: 0)
        case .star: self.init(textScale: 0.28, verticalOffset: 0.05)
        case .flower: self.init(textScale: 0.34, verticalOffset: 0)
        case .cloud: self.init(textScale: 0.32, verticalOffset: 0.07)
        }
    }

    init(textScale: CGFloat, verticalOffset: CGFloat) {
        self.textScale = textScale
        self.verticalOffset = verticalOffset
    }
}

/// 每种形状怎么画（纯几何，测试直接调）。
enum AvatarShapeGeometry {
    static func draw(_ shape: AvatarShape, into b: inout AvatarPathBuilder) {
        switch shape {
        case .circle:
            b.move(CGPoint(x: 1, y: 0.5))
            b.arc(center: center, radius: 0.5, from: 0, to: 2 * .pi)
            b.close()
        case .squircle:
            b.smooth(superellipse(exponent: 4.5, samples: 72))
        case .arch:
            arch(&b)
        case .hexagon:
            b.roundedPolygon(regularPolygon(sides: 6, radius: 0.5, rotation: -.pi / 2), radius: 0.1)
        case .octagon:
            b.roundedPolygon(regularPolygon(sides: 8, radius: 0.52, rotation: .pi / 8), radius: 0.08)
        case .diamond:
            b.roundedPolygon(
                [
                    CGPoint(x: 0.5, y: 0.02), CGPoint(x: 0.98, y: 0.5), CGPoint(x: 0.5, y: 0.98),
                    CGPoint(x: 0.02, y: 0.5),
                ],
                radius: 0.12)
        case .triangle:
            b.roundedPolygon(
                [CGPoint(x: 0.5, y: 0.06), CGPoint(x: 0.97, y: 0.9), CGPoint(x: 0.03, y: 0.9)], radius: 0.13)
        case .shield:
            shield(&b)
        case .leaf:
            b.move(CGPoint(x: 0.12, y: 0.88))
            b.curve(
                to: CGPoint(x: 0.88, y: 0.12), control1: CGPoint(x: 0.08, y: 0.40), control2: CGPoint(x: 0.40, y: 0.08))
            b.curve(
                to: CGPoint(x: 0.12, y: 0.88), control1: CGPoint(x: 0.92, y: 0.60), control2: CGPoint(x: 0.60, y: 0.92))
            b.close()
        case .pebble:
            b.smooth(
                polar(samples: 96) { t in 0.44 + 0.035 * cos(2 * t + 0.6) + 0.02 * sin(3 * t + 1.1) })
        case .sparkle:
            // 四个尖朝上下左右，边往里凹；尖是圆的（|cos|^k 在尖上导数为 0）。
            b.smooth(polar(samples: 120) { t in 0.24 + 0.26 * pow(abs(cos(2 * t)), 2.2) })
        case .star:
            // 五个尖、一个朝上；整体往下挪一点，上下留白一样。
            b.smooth(
                polar(samples: 150, center: CGPoint(x: 0.5, y: 0.545)) { t in
                    0.27 + 0.23 * pow((1 + cos(5 * (t + .pi / 2))) / 2, 1.6)
                })
        case .flower:
            // 六片花瓣，一片朝上。
            b.smooth(polar(samples: 144) { t in 0.29 + 0.21 * pow(abs(cos(3 * (t + .pi / 2))), 0.7) })
        case .scallop:
            b.smooth(polar(samples: 144) { t in 0.47 + 0.03 * cos(12 * t) })
        case .cloud:
            cloud(&b)
        }
    }

    static let center = CGPoint(x: 0.5, y: 0.5)

    /// 右下角状态角标的圆心放在哪儿：从中心朝右下 45° 的射线和轮廓最外面的交点（单位坐标，在对角线上，x、y 一样）。
    /// 圆形是 0.854；四角星、叶子、菱形这些右下角是空的，角标要往里挪到轮廓上，不然浮在形状外面（`InstanceAvatar`）。
    static let badgeAnchors: [AvatarShape: CGFloat] = Dictionary(
        uniqueKeysWithValues: AvatarShape.allCases.map { ($0, badgeAnchor(of: $0)) })

    /// 算 `badgeAnchors`：把轮廓折成线段（`AvatarPathBuilder.outline`），找和对角线 x = y 在中心右下方的交点里最远的那个。
    static func badgeAnchor(of shape: AvatarShape) -> CGFloat {
        var builder = AvatarPathBuilder(recordsOutline: true)
        draw(shape, into: &builder)
        let points = builder.outline
        var anchor: CGFloat?
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            // 线段 a + u (b - a) 上 x - y = 0 的点。
            let denominator = (b.x - a.x) - (b.y - a.y)
            guard abs(denominator) > 1e-12 else { continue }
            let u = -(a.x - a.y) / denominator
            guard u >= 0, u <= 1 else { continue }
            let x = a.x + u * (b.x - a.x)
            guard x > center.x else { continue }
            anchor = max(anchor ?? x, x)
        }
        return anchor ?? 0.85
    }

    /// 正多边形的顶点（外接圆半径 `radius`，第一个顶点在 `rotation` 方向）。
    static func regularPolygon(sides: Int, radius: CGFloat, rotation: CGFloat) -> [CGPoint] {
        (0..<sides).map { i in
            let angle = rotation + CGFloat(i) * 2 * .pi / CGFloat(sides)
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    /// 绕中心一圈的点，半径按角度给（角度从正上方开始，顺时针）。
    static func polar(
        samples: Int, center: CGPoint = center, radius: (CGFloat) -> CGFloat
    ) -> [CGPoint] {
        (0..<samples).map { i in
            let t = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(samples)
            let r = radius(t)
            return CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
        }
    }

    /// 超椭圆（|x|^n + |y|^n = 1，n 越大越方），填满单位正方形。
    static func superellipse(exponent n: CGFloat, samples: Int) -> [CGPoint] {
        (0..<samples).map { i in
            let t = CGFloat(i) * 2 * .pi / CGFloat(samples)
            let c = cos(t)
            let s = sin(t)
            let x = (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
            let y = (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
            return CGPoint(x: 0.5 + 0.5 * x, y: 0.5 + 0.5 * y)
        }
    }

    /// 拱形：上面半圆，下面两个小圆角。
    private static func arch(_ b: inout AvatarPathBuilder) {
        b.move(CGPoint(x: 0.1, y: 0.5))
        b.arc(center: center, radius: 0.4, from: .pi, to: 2 * .pi)
        b.line(CGPoint(x: 0.9, y: 0.84))
        b.arc(center: CGPoint(x: 0.8, y: 0.84), radius: 0.1, from: 0, to: .pi / 2)
        b.line(CGPoint(x: 0.2, y: 0.94))
        b.arc(center: CGPoint(x: 0.2, y: 0.84), radius: 0.1, from: .pi / 2, to: .pi)
        b.close()
    }

    /// 盾牌：上面两个圆角，两边往下弯到底下的尖。
    private static func shield(_ b: inout AvatarPathBuilder) {
        b.move(CGPoint(x: 0.5, y: 0.97))
        b.curve(to: CGPoint(x: 0.9, y: 0.5), control1: CGPoint(x: 0.72, y: 0.88), control2: CGPoint(x: 0.9, y: 0.72))
        b.line(CGPoint(x: 0.9, y: 0.2))
        b.arc(center: CGPoint(x: 0.8, y: 0.2), radius: 0.1, from: 0, to: -.pi / 2)
        b.line(CGPoint(x: 0.2, y: 0.1))
        b.arc(center: CGPoint(x: 0.2, y: 0.2), radius: 0.1, from: -.pi / 2, to: -.pi)
        b.line(CGPoint(x: 0.1, y: 0.5))
        b.curve(to: CGPoint(x: 0.5, y: 0.97), control1: CGPoint(x: 0.1, y: 0.72), control2: CGPoint(x: 0.28, y: 0.88))
        b.close()
    }

    /// 云朵的三个圆（左、上、右），底边是一条直线。
    static let cloudCircles = (
        left: (center: CGPoint(x: 0.27, y: 0.625), radius: CGFloat(0.2)),
        top: (center: CGPoint(x: 0.51, y: 0.445), radius: CGFloat(0.27)),
        right: (center: CGPoint(x: 0.73, y: 0.625), radius: CGFloat(0.2))
    )

    /// 云朵：底边从左圆的底走到右圆的底，绕右圆上去，接上圆，再接左圆回到底边。
    private static func cloud(_ b: inout AvatarPathBuilder) {
        let (left, top, right) = cloudCircles
        let bottom = left.center.y + left.radius
        guard let rightTop = upperIntersection(right, top), let topLeft = upperIntersection(top, left) else {
            b.move(CGPoint(x: 1, y: 0.5))
            b.arc(center: center, radius: 0.5, from: 0, to: 2 * .pi)
            b.close()
            return
        }
        b.move(CGPoint(x: left.center.x, y: bottom))
        b.line(CGPoint(x: right.center.x, y: bottom))
        b.arc(
            center: right.center, radius: right.radius, from: .pi / 2, to: below(angle(rightTop, right.center), .pi / 2)
        )
        let topStart = angle(rightTop, top.center)
        b.arc(center: top.center, radius: top.radius, from: topStart, to: below(angle(topLeft, top.center), topStart))
        let leftStart = angle(topLeft, left.center)
        b.arc(center: left.center, radius: left.radius, from: leftStart, to: below(.pi / 2, leftStart))
        b.close()
    }

    /// 两个圆靠上的那个交点；不相交时为 nil。
    static func upperIntersection(
        _ a: (center: CGPoint, radius: CGFloat), _ c: (center: CGPoint, radius: CGFloat)
    ) -> CGPoint? {
        let dx = c.center.x - a.center.x
        let dy = c.center.y - a.center.y
        let d = (dx * dx + dy * dy).squareRoot()
        guard d > 0, d < a.radius + c.radius, d > abs(a.radius - c.radius) else { return nil }
        let along = (a.radius * a.radius - c.radius * c.radius + d * d) / (2 * d)
        let h = (a.radius * a.radius - along * along).squareRoot()
        let mid = CGPoint(x: a.center.x + along * dx / d, y: a.center.y + along * dy / d)
        let p1 = CGPoint(x: mid.x + h * dy / d, y: mid.y - h * dx / d)
        let p2 = CGPoint(x: mid.x - h * dy / d, y: mid.y + h * dx / d)
        return p1.y < p2.y ? p1 : p2
    }

    private static func angle(_ point: CGPoint, _ center: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }

    /// 和 `angle` 同一个方向、但比 `reference` 小的角度（逆着角度走一段弧用）。
    private static func below(_ angle: CGFloat, _ reference: CGFloat) -> CGFloat {
        var a = angle
        while a >= reference { a -= 2 * .pi }
        while a < reference - 2 * .pi { a += 2 * .pi }
        return a
    }
}

/// 在单位正方形里画路径，换成视图的点。
struct AvatarPathBuilder {
    private(set) var path = Path()
    let origin: CGPoint
    let side: CGFloat
    /// 用到的所有点（端点和控制点）在单位坐标里的范围：曲线一定在它里面（测试查形状没出界、不太小）。
    private(set) var unitBounds: (minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat) = (1, 1, 0, 0)
    /// 轮廓折成的点（单位坐标，曲线每段取 `outlineSteps` 个点）；只在 `recordsOutline` 时记（算角标位置用，画的时候不记）。
    private(set) var outline: [CGPoint] = []
    private let recordsOutline: Bool
    /// 当前点（单位坐标），曲线取样从这里起。
    private var current = CGPoint.zero
    private static let outlineSteps = 16

    init(origin: CGPoint = .zero, side: CGFloat = 1, recordsOutline: Bool = false) {
        self.origin = origin
        self.side = side
        self.recordsOutline = recordsOutline
    }

    private mutating func point(_ p: CGPoint) -> CGPoint {
        unitBounds = (
            min(unitBounds.minX, p.x), min(unitBounds.minY, p.y), max(unitBounds.maxX, p.x), max(unitBounds.maxY, p.y)
        )
        return CGPoint(x: origin.x + p.x * side, y: origin.y + p.y * side)
    }

    mutating func move(_ p: CGPoint) {
        path.move(to: point(p))
        if recordsOutline { outline.append(p) }
        current = p
    }

    mutating func line(_ p: CGPoint) {
        path.addLine(to: point(p))
        if recordsOutline { outline.append(p) }
        current = p
    }

    mutating func curve(to p: CGPoint, control1: CGPoint, control2: CGPoint) {
        let end = point(p)
        let c1 = point(control1)
        let c2 = point(control2)
        path.addCurve(to: end, control1: c1, control2: c2)
        if recordsOutline {
            let start = current
            for step in 1...Self.outlineSteps {
                let t = CGFloat(step) / CGFloat(Self.outlineSteps)
                let s = 1 - t
                let w0 = s * s * s
                let w1 = 3 * s * s * t
                let w2 = 3 * s * t * t
                let w3 = t * t * t
                outline.append(
                    CGPoint(
                        x: w0 * start.x + w1 * control1.x + w2 * control2.x + w3 * p.x,
                        y: w0 * start.y + w1 * control1.y + w2 * control2.y + w3 * p.y))
            }
        }
        current = p
    }

    mutating func close() {
        path.closeSubpath()
    }

    /// 圆弧（弧度，y 向下：0 朝右、π/2 朝下；`to` 比 `from` 小就逆着走），从当前点（弧的起点）画起。每段不超过 90°，
    /// 用三次贝塞尔近似。
    mutating func arc(center: CGPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat) {
        let total = end - start
        let segments = max(1, Int((abs(total) / (.pi / 2)).rounded(.up)))
        let step = total / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4) * radius
        for i in 0..<segments {
            let a0 = start + CGFloat(i) * step
            let a1 = a0 + step
            let p0 = CGPoint(x: center.x + radius * cos(a0), y: center.y + radius * sin(a0))
            let p1 = CGPoint(x: center.x + radius * cos(a1), y: center.y + radius * sin(a1))
            curve(
                to: p1, control1: CGPoint(x: p0.x - k * sin(a0), y: p0.y + k * cos(a0)),
                control2: CGPoint(x: p1.x + k * sin(a1), y: p1.y - k * cos(a1)))
        }
    }

    /// 圆角多边形：每个角用半径 `radius` 的圆弧倒圆（边太短时缩小，最多到边长的一半）。
    mutating func roundedPolygon(_ vertices: [CGPoint], radius: CGFloat) {
        let n = vertices.count
        guard n >= 3 else { return }
        for i in 0..<n {
            let v = vertices[i]
            let previous = vertices[(i + n - 1) % n]
            let next = vertices[(i + 1) % n]
            let toPrevious = Self.unit(from: v, to: previous)
            let toNext = Self.unit(from: v, to: next)
            let cosine = max(-1, min(1, toPrevious.x * toNext.x + toPrevious.y * toNext.y))
            let interior = acos(cosine)
            let limit = min(Self.distance(v, previous), Self.distance(v, next)) / 2
            let tangent = min(radius / tan(interior / 2), limit)
            let filletRadius = tangent * tan(interior / 2)
            let handle = 4 / 3 * tan((.pi - interior) / 4) * filletRadius
            let a = CGPoint(x: v.x + toPrevious.x * tangent, y: v.y + toPrevious.y * tangent)
            let b = CGPoint(x: v.x + toNext.x * tangent, y: v.y + toNext.y * tangent)
            if i == 0 { move(a) } else { line(a) }
            curve(
                to: b, control1: CGPoint(x: a.x - toPrevious.x * handle, y: a.y - toPrevious.y * handle),
                control2: CGPoint(x: b.x - toNext.x * handle, y: b.y - toNext.y * handle))
        }
        close()
    }

    /// 穿过这些点的闭合平滑曲线（Catmull-Rom 换成三次贝塞尔）。
    mutating func smooth(_ points: [CGPoint]) {
        let n = points.count
        guard n >= 3 else { return }
        move(points[0])
        for i in 0..<n {
            let p0 = points[(i + n - 1) % n]
            let p1 = points[i]
            let p2 = points[(i + 1) % n]
            let p3 = points[(i + 2) % n]
            curve(
                to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        close()
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
    }

    private static func unit(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let d = distance(a, b)
        guard d > 0 else { return .zero }
        return CGPoint(x: (b.x - a.x) / d, y: (b.y - a.y) / d)
    }
}
