import Foundation
import SwiftUI
import ThinktinKit

// Botin 头像的脸（规范 docs/ios-ui-redesign.md 4.4.4、4.7.1）：头像形状上开两只竖着的椭圆眼睛（挖空，透出底下的
// 背景）。有任务在跑时（`BotinFaceMood.active`）会眨眼、往四处看、隔一阵随机做个小动作（跳一下、歪头、笑一下、点头，
// 时间表在 ThinktinKit 的 `BotinFaceLife`）；没在跑的一动不动（用户 2026-11-06：“没有运行中的会话就不要眨眼或者有动作了”），
// 只在用户点了、挑了东西时做一下反应。换形状时身体平滑地变过去，颜色跟着渐变。只有 Botin 有脸，引擎、模型厂商、账号
// 还是首字（`AvatarGlyph`、`EngineIcon`、`CredentialVendorIcon`、`AccountAvatar`）。
//
// 做法参考了开源项目 bloub（MIT，仿 x.ai 机器人头像）的思路：身体用从中心出发的一圈半径表示，两种形状之间按半径插值
// 就是变形；眼睛是挖出来的洞。没有拷它的代码和量出来的数值，也不照搬 x.ai 的样子和动作编排：眼睛是正对前方、不歪的
// 椭圆，笑起来弯成“∩”，大小、位置、眨眼和转眼的节奏、小动作、变形的时长都是我们自己定的。
//
// 坐标和 `AvatarShapePath` 一样在单位正方形里（0…1，y 向下），画的时候等比、居中地放进给定的矩形。身体的挪动、伸缩、
// 歪是一个仿射变换（`BotinBodyTransform`），身体和眼睛一起变，眼睛总在身体里面。
//
// 重画只在动的时候：`active` 的头像在眨眼、转眼、小动作的窗口里逐帧画（`BotinFaceSchedule`），窗口之间一帧都不画；
// 别的状态不用 `TimelineView`，只在反应的那一小会儿给一个。系统打开“减弱动态效果”时都不动、不做反应，换形状也不做
// 动画；截图时 App 用 `botinFaceMotion` 关掉，每次截出来的一样。

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
        let ray = Vector(x: cos(angle), y: sin(angle))
        return outline.indices.compactMap { i -> Double? in
            let start = outline[i]
            let end = outline[(i + 1) % outline.count]
            // 射线“中心 + s × ray”和线段“start + u × edge”的交点（课本上的解法，两边各和 edge、ray 做叉积）：
            // s = (toStart × edge) / (ray × edge)，u = (toStart × ray) / (ray × edge)。u 两头各放宽一点，穿过顶点时不漏。
            let edge = Vector(x: Double(end.x - start.x), y: Double(end.y - start.y))
            let toStart = Vector(x: Double(start.x - center.x), y: Double(start.y - center.y))
            let det = ray.cross(edge)
            // 射线和这条边平行：碰不到（或者沿着边走，旁边的边会碰到）。
            guard abs(det) > 1e-12 else { return nil }
            let s = toStart.cross(edge) / det
            let u = toStart.cross(ray) / det
            return u >= -1e-9 && u <= 1 + 1e-9 && s > 0 ? s : nil
        }
    }

    /// 平面上的向量（`hits(on:angle:)` 用）。
    private struct Vector {
        var x: Double
        var y: Double

        /// 叉积（z 分量）：self × other。
        func cross(_ other: Vector) -> Double {
            x * other.y - y * other.x
        }
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

/// 眼睛的大小、位置、看向时挪多远、笑眼的样子（单位正方形里，都是我们自己定的）。
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
    /// 笑眼（“∩”）：下边是上边压到多高（0.55 倍，中间厚、两头细的一道弯），整只眼睛往上提眼睛高度的多少。
    static let smileUnderside = 0.55
    static let smileLift = 0.15
    /// 笑眼按多少个点画：同一个角度参数从椭圆往“∩”插值，穿过这些点画平滑曲线。
    static let smileSamples = 48

    /// 脸（两只眼睛的中心）在形状上的高度；横向总在正中间。重心偏下、上面窄的（三角形、云朵）往下放，盾牌往上放。
    /// 每种形状、看到最远的时候（笑眼、睁大眼、跳起来的时候也是）眼睛离形状的边都留着余量（测试查）。
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

    /// 一只眼睛：中心、宽、高（单位坐标，身体变换以前），笑的程度。
    struct Eye: Hashable, Sendable {
        var centerX: Double
        var centerY: Double
        var width: Double
        var height: Double
        /// 0 椭圆，1 “∩”。
        var smile: Double = 0
    }

    /// 这个样子下的两只眼睛（先左后右，身体变换以前的位置）。样子先夹回能画的范围（`Pose.clamped()`，NaN 当不动），
    /// 眼睛不会跑出形状。睁大（`eyeScale`）以眼睛中心为准，眨眼（`lid`）只压高度。
    static func eyes(faceY: Double, pose: BotinFaceLife.Pose) -> [Eye] {
        let pose = pose.clamped()
        let dx = pose.gazeX * gazeReachX
        let dy = pose.gazeY < 0 ? pose.gazeY * gazeReachUp : pose.gazeY * gazeReachDown
        return [-1.0, 1.0].map { side in
            Eye(
                centerX: 0.5 + side * eyeOffset + dx, centerY: faceY + dy,
                width: eyeWidth * pose.eyeScale * (1 - foreshortening * max(0, side * pose.gazeX)),
                height: eyeHeight * pose.eyeScale * pose.lid, smile: pose.smile)
        }
    }

    /// 笑眼上的点（`smileSamples` 个，从最右边起，y 向下时顺时针）：同一个角度 φ 上椭圆的点和“∩”的点按 `smile` 插值。
    /// “∩”和椭圆一样宽：上半边就是椭圆的上半边，下半边是上半边压到 `smileUnderside` 倍高（两头在椭圆的左右端点接上，
    /// 中间厚、两头细），整只往上提 `smileLift` 倍的眼睛高。眨眼时一样压扁（高度里已经乘了 `lid`）。
    static func smilePoints(_ eye: Eye) -> [CGPoint] {
        let rx = eye.width / 2
        let ry = eye.height / 2
        let smile = min(1, max(0, eye.smile))
        let lift = smileLift * eye.height * smile
        return (0..<smileSamples).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(smileSamples)
            let s = sin(angle)
            let ellipseY = eye.centerY + ry * s
            // 下半边（s > 0，y 向下）换成上半边同一个 x 处的弧，高度压到 0.55 倍。
            let arcY = s < 0 ? ellipseY : eye.centerY - smileUnderside * ry * s
            return CGPoint(x: eye.centerX + rx * cos(angle), y: ellipseY + (arcY - ellipseY) * smile - lift)
        }
    }
}

/// 身体（连同眼睛）此刻怎么变（`Pose` 的 `squashX`、`squashY`、`tilt`、`bodyOffsetY`）：先以身体最下面的中点为准横竖
/// 伸缩（脚底不动），再绕 (0.5, 0.5) 歪（正的顺时针），最后上下挪。是仿射变换：三次贝塞尔的端点、控制点变换过去就是
/// 变换后的曲线，所以直接变换点；身体和眼睛一起变，眼睛在身体里面的话变完还在里面。
struct BotinBodyTransform: Sendable {
    let squashX: Double
    let squashY: Double
    let offsetY: Double
    /// 伸缩的基准点的高度（身体最下面的点；横向在正中）。
    let bottom: Double
    private let cosine: Double
    private let sine: Double
    let isIdentity: Bool

    /// 不变。
    static let identity = BotinBodyTransform(pose: BotinFaceLife.restPose, bottom: 1)

    /// `pose` 要先夹过（`Pose.clamped()`）。`shift` 是在 `bodyOffsetY` 以外再往下挪多少（头顶冒出太多时挪回来，
    /// `BotinFaceShape.transform(body:pose:)`）。
    init(pose: BotinFaceLife.Pose, bottom: Double, shift: Double = 0) {
        squashX = pose.squashX
        squashY = pose.squashY
        offsetY = pose.bodyOffsetY + shift
        self.bottom = bottom
        cosine = cos(pose.tilt)
        sine = sin(pose.tilt)
        isIdentity = pose.squashX == 1 && pose.squashY == 1 && pose.tilt == 0 && offsetY == 0
    }

    /// 两点之间的距离变换后至少是原来的几倍：歪、挪不改距离，伸缩取小的那个（测试按它换算眼睛离边的余量）。
    var minimumScale: Double { min(squashX, squashY) }

    func apply(_ point: CGPoint) -> CGPoint {
        guard !isIdentity else { return point }
        let dx = (Double(point.x) - 0.5) * squashX
        let dy = bottom + (Double(point.y) - bottom) * squashY - 0.5
        return CGPoint(x: 0.5 + cosine * dx - sine * dy, y: 0.5 + sine * dx + cosine * dy + offsetY)
    }
}

// MARK: - 形状

/// 脸的路径：径向轮廓画成的身体，两只眼睛挖空（同一条路径，用奇偶规则填：`FillStyle(eoFill: true)`；眼睛总在身体
/// 里面，测试查）。身体的半径和脸的高度能做动画（换形状时变形）；看向、眨眼、笑眼、身体的挪动伸缩不做动画（按时间表
/// 逐帧给）。
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

    /// 身体轮廓上的点：每个方向一个（半径缺的当 0），变换以前。
    nonisolated static func bodyPoints(_ radii: AvatarRadii) -> [CGPoint] {
        let center = AvatarRadialProfile.center
        return (0..<AvatarRadialProfile.sampleCount).map { i in
            let angle = AvatarRadialProfile.angle(at: i)
            let r = radii[i]
            return CGPoint(x: center.x + CGFloat(r * cos(angle)), y: center.y + CGFloat(r * sin(angle)))
        }
    }

    /// 这个样子下身体怎么变：伸缩的基准是身体最下面的点（换形状的半路上也按那一刻的轮廓算）。变完头顶冒出方框上沿
    /// 超过 `BotinFaceLife.Limits.lift` 时（几次反应叠在一起、歪着头又跳起来），整个往下挪回来，头顶正好贴着这条线：
    /// 挪多少随样子连续地变，不会一跳；只是平移，眼睛还在身体里面。
    nonisolated static func transform(body: [CGPoint], pose: BotinFaceLife.Pose) -> BotinBodyTransform {
        let bottom = body.map { Double($0.y) }.max() ?? 1
        let transform = BotinBodyTransform(pose: pose, bottom: bottom)
        let limit = -BotinFaceLife.Limits.lift
        guard !transform.isIdentity, let top = body.map({ Double(transform.apply($0).y) }).min(), top < limit else {
            return transform
        }
        return BotinBodyTransform(pose: pose, bottom: bottom, shift: limit - top)
    }

    /// 画身体（穿过 `bodyPoints` 的闭合平滑曲线）和两只眼睛，都按这个样子变换过。
    nonisolated static func draw(
        radii: AvatarRadii, faceY: Double, pose: BotinFaceLife.Pose, into builder: inout AvatarPathBuilder
    ) {
        let pose = pose.clamped()
        let body = bodyPoints(radii)
        let transform = transform(body: body, pose: pose)
        builder.smooth(body.map(transform.apply))
        for eye in BotinFaceLayout.eyes(faceY: faceY, pose: pose) {
            drawEye(eye, transform: transform, into: &builder)
        }
    }

    /// 一只眼睛。不笑时是椭圆：从最右边的点起，顺时针四段（每段四分之一椭圆的三次贝塞尔）；笑的时候（`smile` 大于 0）
    /// 是穿过 `BotinFaceLayout.smilePoints` 的闭合平滑曲线。点都按 `transform` 变换。
    nonisolated static func drawEye(
        _ eye: BotinFaceLayout.Eye, transform: BotinBodyTransform = .identity, into builder: inout AvatarPathBuilder
    ) {
        if eye.smile > 0 {
            builder.smooth(BotinFaceLayout.smilePoints(eye).map(transform.apply))
            return
        }
        // 四分之一圆弧用三次贝塞尔近似时控制柄的长度（半径的倍数）。
        let k = 4.0 / 3.0 * (2.0.squareRoot() - 1)
        let x = eye.centerX
        let y = eye.centerY
        let rx = eye.width / 2
        let ry = eye.height / 2
        func point(_ px: Double, _ py: Double) -> CGPoint { transform.apply(CGPoint(x: px, y: py)) }
        builder.move(point(x + rx, y))
        builder.curve(to: point(x, y + ry), control1: point(x + rx, y + k * ry), control2: point(x + k * rx, y + ry))
        builder.curve(to: point(x - rx, y), control1: point(x - k * rx, y + ry), control2: point(x - rx, y + k * ry))
        builder.curve(to: point(x, y - ry), control1: point(x - rx, y - k * ry), control2: point(x - k * rx, y - ry))
        builder.curve(to: point(x + rx, y), control1: point(x + k * rx, y - ry), control2: point(x + rx, y - k * ry))
        builder.close()
    }

    /// 身体和两只眼睛各自折成的点（单位坐标，按这个样子变换过；测试查眼睛在身体里面、身体贴着原来的形状）。
    nonisolated static func outlines(
        radii: AvatarRadii, faceY: Double, pose: BotinFaceLife.Pose
    ) -> (body: [CGPoint], eyes: [[CGPoint]]) {
        let pose = pose.clamped()
        let points = bodyPoints(radii)
        let transform = transform(body: points, pose: pose)
        var body = AvatarPathBuilder(recordsOutline: true)
        body.smooth(points.map(transform.apply))
        let eyes = BotinFaceLayout.eyes(faceY: faceY, pose: pose).map { eye in
            var builder = AvatarPathBuilder(recordsOutline: true)
            drawEye(eye, transform: transform, into: &builder)
            return builder.outline
        }
        return (body.outline, eyes)
    }
}

// MARK: - 什么时候重画

/// 脸的时间线：只在动的窗口里逐帧给时刻（窗口的开头、每隔 `frameInterval` 一帧、正好在窗口的结尾），窗口之间一个都不给，
/// 那时样子不变，不用重画。`active` 的窗口是眨眼、转眼、随机的小动作，别的状态只有反应的窗口（做完就不再给）。按需
/// 一个个往后算，不会用完也不会停在原地。
struct BotinFaceSchedule: TimelineSchedule, Sendable {
    let life: BotinFaceLife
    let mood: BotinFaceMood
    /// 这次进入 `mood` 的时刻（`BotinFaceLife.pose(at:mood:since:reactions:)`）：`active` 时这以前开始的窗口不算。
    let since: TimeInterval
    let reactions: [BotinFaceReaction]
    /// 窗口里两帧之间最多隔多久。
    let frameInterval: TimeInterval

    /// `frameInterval` 不是正的有限数时按 1/60 秒。
    init(
        life: BotinFaceLife, mood: BotinFaceMood, since: TimeInterval = -.infinity,
        reactions: [BotinFaceReaction] = [], frameInterval: TimeInterval
    ) {
        self.life = life
        self.mood = mood
        self.since = since
        self.reactions = reactions
        self.frameInterval = frameInterval.isFinite && frameInterval > 0 ? frameInterval : 1.0 / 60
    }

    /// 边长 `side` 的头像窗口里多久一帧：小头像（列表、标题，小于 60pt）每秒 30 帧就够，大的每秒 60 帧。
    static func frameInterval(forSide side: CGFloat) -> TimeInterval {
        side < 60 ? 1.0 / 30 : 1.0 / 60
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        if case .lowFrequency = mode {
            return Entries(schedule: self, first: restingTime(from: startDate), once: true)
        }
        return Entries(schedule: self, first: startDate.timeIntervalSinceReferenceDate, once: false)
    }

    /// `t` 以后最早的动的窗口（`BotinFaceLife.nextActiveWindow`）。
    func nextWindow(after t: TimeInterval) -> ClosedRange<TimeInterval> {
        life.nextActiveWindow(after: t, mood: mood, since: since, reactions: reactions)
    }

    /// 低频模式（息屏显示这类）只给一个时刻：`startDate`；它在动的窗口里时给窗口的结尾（不在半路）。
    private func restingTime(from startDate: Date) -> TimeInterval {
        var t = startDate.timeIntervalSinceReferenceDate
        // 窗口可能一个接一个地重叠（小动作的时候眨眼、几次反应叠在一起），最多往后跳几次。
        for _ in 0..<8 {
            let window = nextWindow(after: t)
            guard window.lowerBound <= t, window.upperBound > t else { break }
            t = window.upperBound
        }
        return t
    }

    struct Entries: Sequence, IteratorProtocol {
        let schedule: BotinFaceSchedule
        /// 还没给出去的第一个时刻。
        private var first: TimeInterval?
        /// 上一个给出去的时刻；nil 表示没有更多了。
        private var last: TimeInterval?
        /// 只给一个（低频模式）。
        private let once: Bool

        init(schedule: BotinFaceSchedule, first: TimeInterval, once: Bool) {
            self.schedule = schedule
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
            let window = schedule.nextWindow(after: previous)
            // 在窗口外：跳到窗口的开头；在窗口里：下一帧，最后正好落在结尾。
            let t =
                window.lowerBound > previous
                ? window.lowerBound : Swift.min(previous + schedule.frameInterval, window.upperBound)
            // 再也不会动了（+∞），或者时间太远、不是有限数（`BotinFaceLife` 给的是空窗口），往后走不动了就结束（不原地打转）。
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

/// Botin 的头像：形状填上颜色、两只眼睛挖空。`mood` 是 `active`（有任务在跑、选头像时选中的那个）时眨眼、往四处看、
/// 隔一阵随机做个小动作，只在动的时候重画；别的状态画一张不动的脸（不用 `TimelineView`，一帧都不重画）。`reactions`
/// 是用户点了、挑了东西时的反应，不管什么状态都做，做的那一小会儿给一个时间线、做完换回不动的。换形状时变形、挑颜色时
/// 渐变。变成 `active`（出现时就是、刚开始跑、刚选中）时从不动的样子开始动（`BotinLiveFace.since`）；从 `active` 换成
/// 别的状态时直接换成不动的脸，正在做的随机小动作不做完（用户定的“没在跑就不动”），反应照样做完。系统打开“减弱动态效果”
/// 或者环境里 `botinFaceMotion` 为 false 时都不动（`active` 也画不动的样子）、不做反应。按给的边长画，不跟动态字体缩放；
/// 读屏由调用方处理（自己不念）。跳起来时头顶会冒出方框上沿，最多 `BotinFaceLife.Limits.lift` 倍边长：放在会切掉内容的
/// 地方时调用方在上面留出来。
struct BotinFace: View {
    let name: String
    let appearance: InstanceAppearance
    let size: CGFloat
    /// 此刻的状态（`InstanceAvatar` 从角标推，选头像的地方直接给）。
    var mood: BotinFaceMood = .resting
    /// 最近的几次反应（`BotinFaceReaction.adding`，调用方放在 `@State` 里）。
    var reactions: [BotinFaceReaction] = []
    /// 眨眼、看向、小动作的节奏；nil 时按名字定（`BotinFaceLife(name:)`）。名字边打边变的地方（新建表单的预览）给一个
    /// 固定的，不然每敲一个字换一次种子，眼睛一跳一跳的。
    var life: BotinFaceLife?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.botinFaceMotion) private var botinFaceMotion
    /// 反应做完了几回（`.task` 睡到最后一次反应做完时加一）：改了它视图重算一遍，不是 `active` 的换回不动的脸。
    @State private var settledCount = 0

    /// 换形状、挑颜色的动画：利落、略带一点回弹（时长、回弹是我们自己定的）。
    static let morph = Animation.snappy(duration: 0.42, extraBounce: 0.12)

    var body: some View {
        let color = appearance.resolvedColor(name: name)
        let colors = InstanceAvatar.colors(of: color)
        let fill = Color(light: colors.light, dark: colors.dark)
        let moves = Self.motionAllowed(reduceMotion: reduceMotion, botinFaceMotion: botinFaceMotion)
        // 还没做完的反应（正在做的、还没开始的）里最晚的结尾。关了动效时不做。
        let pendingEnd =
            moves ? BotinFaceReaction.pendingEnd(reactions, now: Date().timeIntervalSinceReferenceDate) : nil
        face(fill: fill, live: moves && (mood.isAlive || pendingEnd != nil))
            .frame(width: size, height: size)
            .animation(moves ? Self.morph : nil, value: appearance.shape)
            // 只在挑颜色时渐变：没挑颜色时按名字取的颜色跟着名字变，打名字时直接换（不然每敲一个字，预览和十五个格子都闪一下）。
            .animation(moves ? Self.morph : nil, value: appearance.color)
            // 睡到最后一次反应做完，再让视图重算一遍（换回不动的脸）；又来了反应时重新睡。醒早了一点也没关系：重算时还没做完，
            // `settledCount` 变了，再睡剩下的一点。
            .task(id: ReactionTimer(end: pendingEnd, settled: settledCount)) {
                guard let pendingEnd else { return }
                let delay = pendingEnd - Date().timeIntervalSinceReferenceDate
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                if !Task.isCancelled { settledCount += 1 }
            }
    }

    /// `live` 时用 `TimelineView` 按时间表逐帧画。时间表里有反应：来了新的反应，调用方给的 `reactions` 变了，时间表跟着
    /// 变，`TimelineView` 按新的时间表重新取时刻（系统的 `.animation(paused:)` 也是靠换时间表停、走）。不按反应换 `id`：
    /// 换了 id 里面的脸是新建的，正在做的变形、渐变动画会被打断（挑了形状以后预览就是一边变形一边等着笑）。按状态换 `id`：
    /// 状态变了是新的一段，`BotinLiveFace` 重新记开始的时刻（状态很少变，变的时候一般不在变形；从不动的那一支换过来本来
    /// 就是新建的）。
    @ViewBuilder
    private func face(fill: Color, live: Bool) -> some View {
        if live {
            BotinLiveFace(
                life: life ?? BotinFaceLife(name: name), shape: appearance.shape, fill: fill, mood: mood,
                reactions: reactions, frameInterval: BotinFaceSchedule.frameInterval(forSide: size)
            )
            .id(mood)
        } else {
            BotinFaceShape(shape: appearance.shape, pose: BotinFaceLife.restPose(for: mood))
                .fill(fill, style: FillStyle(eoFill: true))
        }
    }

    /// 能不能动：系统没开“减弱动态效果”、环境里也没关（截图时关）。
    nonisolated static func motionAllowed(reduceMotion: Bool, botinFaceMotion: Bool) -> Bool {
        !reduceMotion && botinFaceMotion
    }

    /// 等反应做完的那个 `.task` 的 id：最晚的结尾、做完了几回，有一个变了就重新等。
    private struct ReactionTimer: Equatable {
        var end: TimeInterval?
        var settled: Int
    }
}

/// 活的脸（`BotinFace` 在动的那一支）：`TimelineView` 按时间表（`BotinFaceSchedule`）逐帧画。`since` 是这一支出现的
/// 时刻（`BotinFace` 的状态变了时给它换 id，重新出现）：`active` 从这一刻起才开始眨眼、转眼、做小动作，第一帧和不动时
/// 一样，之后连续地动（`BotinFaceLife.pose(at:mood:since:reactions:)`）。
private struct BotinLiveFace: View {
    let life: BotinFaceLife
    let shape: AvatarShape
    let fill: Color
    let mood: BotinFaceMood
    let reactions: [BotinFaceReaction]
    let frameInterval: TimeInterval

    /// 出现的时刻：`@State` 只留第一次建这个视图时的值，之后父视图重算也不变。
    @State private var since = Date().timeIntervalSinceReferenceDate

    var body: some View {
        let life = self.life
        let mood = self.mood
        let since = self.since
        let reactions = self.reactions
        let schedule = BotinFaceSchedule(
            life: life, mood: mood, since: since, reactions: reactions, frameInterval: frameInterval)
        TimelineView(schedule) { context in
            let pose = life.pose(
                at: context.date.timeIntervalSinceReferenceDate, mood: mood, since: since, reactions: reactions)
            BotinFaceShape(shape: shape, pose: pose).fill(fill, style: FillStyle(eoFill: true))
        }
    }
}

#Preview("Botin 的脸") {
    VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
        HStack(spacing: Metrics.Spacing.s) {
            ForEach(AvatarShape.allCases.prefix(8), id: \.self) { shape in
                BotinFace(
                    name: "周报助手", appearance: InstanceAppearance(shape: shape), size: Metrics.Avatar.list,
                    mood: .active)
            }
        }
        HStack(spacing: Metrics.Spacing.s) {
            ForEach(AvatarShape.allCases.dropFirst(8), id: \.self) { shape in
                BotinFace(
                    name: "翻译", appearance: InstanceAppearance(shape: shape, color: .teal), size: Metrics.Avatar.list)
            }
        }
        HStack(spacing: Metrics.Spacing.s) {
            ForEach(BotinFaceMood.allCases, id: \.self) { mood in
                BotinFace(
                    name: "盯盘", appearance: InstanceAppearance(shape: .squircle), size: Metrics.Avatar.list, mood: mood)
            }
        }
        BotinFace(name: "写作助手", appearance: InstanceAppearance(shape: .cloud, color: .orchid), size: 120, mood: .active)
    }
    .padding()
    .background(Theme.paper)
}
