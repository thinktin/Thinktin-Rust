import Foundation
import SwiftUI
import ThinktinKit

// Botin 头像的脸（规范 docs/ios-ui-redesign.md 4.4.4、4.7.1）：头像形状上开两只竖着的椭圆眼睛（挖空，透出底下的
// 背景），会眨眼、往四处看（时间表在 ThinktinKit 的 `BotinFaceLife`）；换形状时身体平滑地变过去，颜色跟着渐变。
// 只有 Botin 有脸，引擎、模型厂商、账号还是首字（`AvatarGlyph`、`EngineIcon`、`CredentialVendorIcon`、`AccountAvatar`）。
//
// 做法参考了开源项目 bloub（MIT，仿 x.ai 机器人头像）的思路：身体用从中心出发的一圈半径表示，两种形状之间按半径插值
// 就是变形；眼睛是挖出来的洞。没有拷它的代码和量出来的数值，也不照搬 x.ai 的样子：眼睛是正对前方、不歪的椭圆，
// 大小、位置、眨眼和转眼的节奏都是我们自己定的。
//
// 坐标和 `AvatarShapePath` 一样在单位正方形里（0…1，y 向下），画的时候等比、居中地放进给定的矩形。
//
// 重画只在动的时候：眨眼、转眼的窗口里逐帧画（`BotinFaceSchedule`），窗口之间一帧都不画。系统打开“减弱动态效果”时
// 不眨眼、不转眼，换形状也不做动画；截图时 App 用 `botinFaceMotion` 关掉，每次截出来的一样。

// MARK: - 径向轮廓

/// 形状的径向轮廓：从中心 (0.5, 0.5) 出发、朝 `sampleCount` 个方向（从正上方开始顺时针，和
/// `AvatarShapeGeometry.polar` 一样）到轮廓的距离。15 种形状从中心看都是“星形”的（每个方向只碰到轮廓一次），所以
/// 这一圈半径能代表形状；两种形状按半径插值就是变形。
enum AvatarRadialProfile {
    /// 一圈取多少个方向。120 个时穿过这些点的平滑曲线离原来的轮廓不到 0.005（测试查）。
    static let sampleCount = 120
    static let center = CGPoint(x: 0.5, y: 0.5)

    /// 第 `index` 个方向的角度（弧度，y 向下：-π/2 朝上，0 朝右）。
    static func angle(at index: Int) -> Double {
        -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(sampleCount)
    }

    /// 形状的径向轮廓：第一次用到时算（每种形状算一次，存起来）。
    static func radii(of shape: AvatarShape) -> AvatarRadii {
        cache.withLock { profiles in
            if let cached = profiles[shape] { return cached }
            let profile = makeProfile(of: outline(of: shape))
            profiles[shape] = profile
            return profile
        }
    }

    /// 算好的轮廓（`radii(of:)` 用）。
    private static let cache = Locked<[AvatarShape: AvatarRadii]>([:])

    /// 折线轮廓的径向轮廓：每个方向取最远的交点（射线正好穿过折线的顶点也不会漏掉）。
    static func makeProfile(of outline: [CGPoint]) -> AvatarRadii {
        AvatarRadii((0..<sampleCount).map { hits(on: outline, angle: angle(at: $0)).max() ?? 0.5 })
    }

    /// 形状的轮廓折成的点（`AvatarShapeGeometry.draw` 画出来的，单位坐标，首尾相连）。
    static func outline(of shape: AvatarShape) -> [CGPoint] {
        var builder = AvatarPathBuilder(recordsOutline: true)
        AvatarShapeGeometry.draw(shape, into: &builder)
        return builder.outline
    }

    /// 从中心朝 `angle` 方向的射线和闭合折线 `outline` 的所有交点离中心多远（没去重：穿过顶点时两条边各算一次）。
    static func hits(on outline: [CGPoint], angle: Double) -> [Double] {
        let dx = cos(angle)
        let dy = sin(angle)
        var distances: [Double] = []
        for i in outline.indices {
            let a = outline[i]
            let b = outline[(i + 1) % outline.count]
            // 射线 center + s (dx, dy) 和线段 a + u (b - a) 相交：解两个叉积。u 两头各放宽一点，穿过顶点时不漏。
            let ex = Double(b.x - a.x)
            let ey = Double(b.y - a.y)
            let denominator = dx * ey - dy * ex
            guard abs(denominator) > 1e-12 else { continue }
            let ax = Double(a.x - center.x)
            let ay = Double(a.y - center.y)
            let distance = (ax * ey - ay * ex) / denominator
            let u = (ax * dy - ay * dx) / denominator
            guard u >= -1e-9, u <= 1 + 1e-9, distance > 0 else { continue }
            distances.append(distance)
        }
        return distances
    }
}

/// 一圈半径（`AvatarRadialProfile`），做形状变形的动画数据。空数组是零（SwiftUI 的动画会从 `.zero` 算起）：
/// 长度不一样时短的那边缺的当 0，结果取长的那个长度；比较相等时也把缺的当 0。
struct AvatarRadii: VectorArithmetic, Sendable {
    var values: [Double]

    init(_ values: [Double]) {
        self.values = values
    }

    static var zero: AvatarRadii { AvatarRadii([]) }

    /// 第 `index` 个半径，超出长度的当 0。
    subscript(index: Int) -> Double {
        values.indices.contains(index) ? values[index] : 0
    }

    static func + (lhs: AvatarRadii, rhs: AvatarRadii) -> AvatarRadii {
        var result = lhs
        result += rhs
        return result
    }

    static func - (lhs: AvatarRadii, rhs: AvatarRadii) -> AvatarRadii {
        var result = lhs
        result -= rhs
        return result
    }

    static func += (lhs: inout AvatarRadii, rhs: AvatarRadii) {
        lhs.combine(rhs, sign: 1)
    }

    static func -= (lhs: inout AvatarRadii, rhs: AvatarRadii) {
        lhs.combine(rhs, sign: -1)
    }

    mutating func scale(by rhs: Double) {
        for i in values.indices {
            values[i] *= rhs
        }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    static func == (lhs: AvatarRadii, rhs: AvatarRadii) -> Bool {
        (0..<max(lhs.values.count, rhs.values.count)).allSatisfy { lhs[$0] == rhs[$0] }
    }

    /// 逐个加上（`sign` 为 1）或减去（-1）`other`，自己短的补 0。
    private mutating func combine(_ other: AvatarRadii, sign: Double) {
        if values.count < other.values.count {
            values.append(contentsOf: repeatElement(0, count: other.values.count - values.count))
        }
        for i in other.values.indices {
            values[i] += sign * other.values[i]
        }
    }
}

// MARK: - 脸的版式

/// 眼睛的大小、位置、看向时挪多远（单位正方形里，都是我们自己定的）。
enum BotinFaceLayout {
    /// 一只眼睛睁开时的宽、高（竖着的椭圆）。
    static let eyeWidth = 0.10
    static let eyeHeight = 0.16
    /// 眼睛中心离竖中线多远（两只眼睛中心相距两倍）。
    static let eyeOffset = 0.105
    /// 看到最左、最右时眼睛挪多远；往上、往下（往上多一点，往下少一点，下面一般更窄）。
    static let gazeReachX = 0.04
    static let gazeReachUp = 0.025
    static let gazeReachDown = 0.02
    /// 往一边看时，那一边的眼睛最多窄多少（像转过去了一点）。
    static let foreshortening = 0.15

    /// 脸（两只眼睛的中心）在形状上的高度；横向总在正中间。重心偏下、上面窄的（三角形、云朵）往下放，盾牌往上放。
    /// 每种形状、看到最远的时候眼睛离形状的边都留着余量（测试查）。
    static func faceY(of shape: AvatarShape) -> Double {
        switch shape {
        case .circle, .squircle, .octagon, .pebble, .scallop: 0.47
        case .arch, .sparkle, .flower: 0.50
        case .hexagon, .diamond: 0.48
        case .triangle: 0.60
        case .shield: 0.45
        case .leaf: 0.49
        case .star: 0.52
        case .cloud: 0.56
        }
    }

    /// 一只眼睛：中心、宽、高（单位坐标）。
    struct Eye: Hashable, Sendable {
        var centerX: Double
        var centerY: Double
        var width: Double
        var height: Double
    }

    /// 这个样子下的两只眼睛（先左后右）。看向和睁开的程度先夹到 [-1, 1]、[0.1, 1]（NaN 当不动），眼睛不会跑出形状。
    static func eyes(faceY: Double, pose: BotinFaceLife.Pose) -> [Eye] {
        let gazeX = clamp(pose.gazeX, -1, 1, otherwise: 0)
        let gazeY = clamp(pose.gazeY, -1, 1, otherwise: 0)
        let lid = clamp(pose.lid, 0.1, 1, otherwise: 1)
        let dx = gazeX * gazeReachX
        let dy = gazeY < 0 ? gazeY * gazeReachUp : gazeY * gazeReachDown
        return [-1.0, 1.0].map { side in
            Eye(
                centerX: 0.5 + side * eyeOffset + dx, centerY: faceY + dy,
                width: eyeWidth * (1 - foreshortening * max(0, side * gazeX)), height: eyeHeight * lid)
        }
    }

    /// 夹到 [lower, upper]；NaN 换成 `fallback`（看正前方、睁着眼），不让一个坏值把眼睛画没了。
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double, otherwise fallback: Double) -> Double {
        value.isNaN ? fallback : min(upper, max(lower, value))
    }
}

// MARK: - 形状

/// 脸的路径：径向轮廓画成的身体，两只眼睛挖空（同一条路径，用奇偶规则填：`FillStyle(eoFill: true)`；眼睛总在身体
/// 里面，测试查）。身体的半径和脸的高度能做动画（换形状时变形），看向、眨眼不做动画（按时间表逐帧给）。
struct BotinFaceShape: Shape {
    var radii: AvatarRadii
    var faceY: Double
    var pose: BotinFaceLife.Pose

    nonisolated var animatableData: AnimatablePair<AvatarRadii, Double> {
        get { AnimatablePair(radii, faceY) }
        set {
            radii = newValue.first
            faceY = newValue.second
        }
    }

    /// 和 `animatableData` 一样不绑主线程（SDK 里 `Shape.path(in:)` 是 nonisolated 的要求，SwiftUI 可能在别的线程上取路径）。
    nonisolated func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        var builder = AvatarPathBuilder(
            origin: CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2), side: side)
        Self.draw(radii: radii, faceY: faceY, pose: pose, into: &builder)
        return builder.path
    }
}

extension BotinFaceShape {
    /// 某种形状、某个样子的脸。
    init(shape: AvatarShape, pose: BotinFaceLife.Pose = BotinFaceLife.restPose) {
        self.init(radii: AvatarRadialProfile.radii(of: shape), faceY: BotinFaceLayout.faceY(of: shape), pose: pose)
    }

    /// 身体轮廓上的点：每个方向一个（半径缺的当 0）。
    nonisolated static func bodyPoints(_ radii: AvatarRadii) -> [CGPoint] {
        let center = AvatarRadialProfile.center
        return (0..<AvatarRadialProfile.sampleCount).map { i in
            let angle = AvatarRadialProfile.angle(at: i)
            let r = radii[i]
            return CGPoint(x: center.x + CGFloat(r * cos(angle)), y: center.y + CGFloat(r * sin(angle)))
        }
    }

    /// 画身体（穿过 `bodyPoints` 的闭合平滑曲线）和两只眼睛（各四段三次贝塞尔的椭圆）。
    nonisolated static func draw(
        radii: AvatarRadii, faceY: Double, pose: BotinFaceLife.Pose, into builder: inout AvatarPathBuilder
    ) {
        builder.smooth(bodyPoints(radii))
        for eye in BotinFaceLayout.eyes(faceY: faceY, pose: pose) {
            drawEye(eye, into: &builder)
        }
    }

    /// 一只眼睛：从最右边的点起，顺时针四段（每段四分之一椭圆）。
    nonisolated static func drawEye(_ eye: BotinFaceLayout.Eye, into builder: inout AvatarPathBuilder) {
        // 四分之一圆弧用三次贝塞尔近似时控制柄的长度（半径的倍数）。
        let k = 4.0 / 3.0 * (2.0.squareRoot() - 1)
        let x = eye.centerX
        let y = eye.centerY
        let rx = eye.width / 2
        let ry = eye.height / 2
        func point(_ px: Double, _ py: Double) -> CGPoint { CGPoint(x: px, y: py) }
        builder.move(point(x + rx, y))
        builder.curve(to: point(x, y + ry), control1: point(x + rx, y + k * ry), control2: point(x + k * rx, y + ry))
        builder.curve(to: point(x - rx, y), control1: point(x - k * rx, y + ry), control2: point(x - rx, y + k * ry))
        builder.curve(to: point(x, y - ry), control1: point(x - rx, y - k * ry), control2: point(x - k * rx, y - ry))
        builder.curve(to: point(x + rx, y), control1: point(x + k * rx, y - ry), control2: point(x + rx, y - k * ry))
        builder.close()
    }

    /// 身体和两只眼睛各自折成的点（单位坐标；测试查眼睛在身体里面、身体贴着原来的形状）。
    nonisolated static func outlines(
        radii: AvatarRadii, faceY: Double, pose: BotinFaceLife.Pose
    ) -> (body: [CGPoint], eyes: [[CGPoint]]) {
        var body = AvatarPathBuilder(recordsOutline: true)
        body.smooth(bodyPoints(radii))
        let eyes = BotinFaceLayout.eyes(faceY: faceY, pose: pose).map { eye in
            var builder = AvatarPathBuilder(recordsOutline: true)
            drawEye(eye, into: &builder)
            return builder.outline
        }
        return (body.outline, eyes)
    }
}

// MARK: - 什么时候重画

/// 脸的时间线：只在眨眼、转眼的窗口里逐帧给时刻（窗口的开头、每隔 `frameInterval` 一帧、正好在窗口的结尾），窗口之间
/// 一个都不给，那时样子不变，不用重画。按需一个个往后算，不会用完也不会停在原地。
struct BotinFaceSchedule: TimelineSchedule, Sendable {
    let life: BotinFaceLife
    /// 窗口里两帧之间最多隔多久。
    let frameInterval: TimeInterval

    /// `frameInterval` 不是正的有限数时按 1/60 秒。
    init(life: BotinFaceLife, frameInterval: TimeInterval) {
        self.life = life
        self.frameInterval = frameInterval.isFinite && frameInterval > 0 ? frameInterval : 1.0 / 60
    }

    /// 边长 `side` 的头像窗口里多久一帧：小头像（列表、标题，小于 60pt）每秒 30 帧就够，大的每秒 60 帧。
    static func frameInterval(forSide side: CGFloat) -> TimeInterval {
        side < 60 ? 1.0 / 30 : 1.0 / 60
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        if case .lowFrequency = mode {
            return Entries(life: life, frameInterval: frameInterval, first: restingTime(from: startDate), once: true)
        }
        return Entries(
            life: life, frameInterval: frameInterval, first: startDate.timeIntervalSinceReferenceDate, once: false)
    }

    /// 低频模式（息屏显示这类）只给一个时刻：`startDate`；它在动的窗口里时给窗口的结尾（眼睛睁着、不在半路）。
    private func restingTime(from startDate: Date) -> TimeInterval {
        var t = startDate.timeIntervalSinceReferenceDate
        // 窗口可能一个接一个地重叠（眨眼的时候正好转眼），最多往后跳几次。
        for _ in 0..<4 {
            let window = life.nextActiveWindow(after: t)
            guard window.lowerBound <= t, window.upperBound > t else { break }
            t = window.upperBound
        }
        return t
    }

    struct Entries: Sequence, IteratorProtocol {
        let life: BotinFaceLife
        let frameInterval: TimeInterval
        /// 还没给出去的第一个时刻。
        private var first: TimeInterval?
        /// 上一个给出去的时刻；nil 表示没有更多了。
        private var last: TimeInterval?
        /// 只给一个（低频模式）。
        private let once: Bool

        init(life: BotinFaceLife, frameInterval: TimeInterval, first: TimeInterval, once: Bool) {
            self.life = life
            self.frameInterval = frameInterval
            self.first = first
            self.once = once
        }

        mutating func next() -> Date? {
            if let first {
                self.first = nil
                last = once ? nil : first
                return Date(timeIntervalSinceReferenceDate: first)
            }
            guard let previous = last else { return nil }
            let window = life.nextActiveWindow(after: previous)
            // 在窗口外：跳到窗口的开头；在窗口里：下一帧，最后正好落在结尾。
            let t =
                window.lowerBound > previous
                ? window.lowerBound : Swift.min(previous + frameInterval, window.upperBound)
            // 时间太远、不是有限数时 `BotinFaceLife` 给的是空窗口，往后走不动了就结束（不原地打转）。
            guard t.isFinite, t > previous else {
                last = nil
                return nil
            }
            last = t
            return Date(timeIntervalSinceReferenceDate: t)
        }
    }
}

// MARK: - 视图

/// Botin 的头像：形状填上颜色、两只眼睛挖空。`live` 时会眨眼、往四处看（只在动的时候重画）；换形状时变形、换颜色时
/// 渐变。系统打开“减弱动态效果”或者环境里 `botinFaceMotion` 为 false 时都不动。按给的边长画，不跟动态字体缩放；
/// 读屏由调用方处理（自己不念）。
struct BotinFace: View {
    let name: String
    let appearance: InstanceAppearance
    let size: CGFloat
    /// 眨眼、看向（选形状的格子里用 false：一屏十几个一起眨眼太闹）。
    var live = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.botinFaceMotion) private var botinFaceMotion

    /// 换形状、换颜色的动画：利落、略带一点回弹。
    static let morph = Animation.snappy(duration: 0.45, extraBounce: 0.12)

    var body: some View {
        let color = appearance.resolvedColor(name: name)
        let colors = InstanceAvatar.colors(of: color)
        let fill = Color(light: colors.light, dark: colors.dark)
        let moves = Self.motionAllowed(reduceMotion: reduceMotion, botinFaceMotion: botinFaceMotion)
        face(fill: fill, animated: live && moves)
            .frame(width: size, height: size)
            .animation(moves ? Self.morph : nil, value: appearance.shape)
            .animation(moves ? Self.morph : nil, value: color)
    }

    @ViewBuilder
    private func face(fill: Color, animated: Bool) -> some View {
        if animated {
            let life = BotinFaceLife(name: name)
            let schedule = BotinFaceSchedule(life: life, frameInterval: BotinFaceSchedule.frameInterval(forSide: size))
            TimelineView(schedule) { context in
                let pose = life.pose(at: context.date.timeIntervalSinceReferenceDate)
                BotinFaceShape(shape: appearance.shape, pose: pose).fill(fill, style: FillStyle(eoFill: true))
            }
        } else {
            BotinFaceShape(shape: appearance.shape).fill(fill, style: FillStyle(eoFill: true))
        }
    }

    /// 能不能动：系统没开“减弱动态效果”、环境里也没关（截图时关）。
    nonisolated static func motionAllowed(reduceMotion: Bool, botinFaceMotion: Bool) -> Bool {
        !reduceMotion && botinFaceMotion
    }
}

#Preview("Botin 的脸") {
    VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
        HStack(spacing: Metrics.Spacing.s) {
            ForEach(AvatarShape.allCases.prefix(8), id: \.self) { shape in
                BotinFace(name: "周报助手", appearance: InstanceAppearance(shape: shape), size: Metrics.Avatar.list)
            }
        }
        HStack(spacing: Metrics.Spacing.s) {
            ForEach(AvatarShape.allCases.dropFirst(8), id: \.self) { shape in
                BotinFace(
                    name: "翻译", appearance: InstanceAppearance(shape: shape, color: .teal), size: Metrics.Avatar.list,
                    live: false)
            }
        }
        BotinFace(name: "写作助手", appearance: InstanceAppearance(shape: .cloud, color: .orchid), size: 120)
    }
    .padding()
    .background(Theme.paper)
}
