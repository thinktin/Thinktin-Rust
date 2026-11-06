import Foundation
import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// Botin 头像的脸（docs/ios-ui-redesign.md 4.4.4）：径向轮廓贴着原来的形状、眼睛在身体里面（换形状的半路上也是）、
/// 变形的动画数据、只在动的时候重画的时间线、各种形状和颜色都画得出来。
@MainActor
@Suite("Botin 的脸")
struct BotinFaceTests {
    private typealias Pose = BotinFaceLife.Pose

    /// 看到最远的九个方向（左中右 × 上中下），眼睛睁着。
    private let gazeExtremes: [Pose] = [-1.0, 0, 1].flatMap { x in
        [-1.0, 0, 1].map { y in Pose(gazeX: x, gazeY: y, lid: 1) }
    }

    @Test("径向轮廓：每种形状 120 个有限的半径，都在 0.2 到 0.62 之间")
    func profiles() {
        for shape in AvatarShape.allCases {
            let radii = AvatarRadialProfile.radii(of: shape)
            #expect(radii.values.count == 120, "\(shape)")
            #expect(radii.values.allSatisfy { $0.isFinite && $0 > 0.2 && $0 < 0.62 }, "\(shape): \(radii.values)")
            // 存起来的和现算的一样。
            #expect(radii == AvatarRadialProfile.makeProfile(of: AvatarRadialProfile.outline(of: shape)))
        }
        // 圆形每个方向都是 0.5；方向从正上方开始顺时针。
        #expect(AvatarRadialProfile.radii(of: .circle).values.allSatisfy { abs($0 - 0.5) < 1e-3 })
        #expect(abs(AvatarRadialProfile.angle(at: 0) + Double.pi / 2) < 1e-12)
        #expect(abs(AvatarRadialProfile.angle(at: 30)) < 1e-12)
        // 四角星的尖朝上下左右，45° 方向最窄。
        let sparkle = AvatarRadialProfile.radii(of: .sparkle)
        #expect(abs(sparkle[0] - 0.5) < 0.005 && abs(sparkle[15] - 0.24) < 0.005)
    }

    @Test("每条射线和每种形状的轮廓只交一次（从中心看都是星形的）")
    func raysCrossOnce() {
        for shape in AvatarShape.allCases {
            let outline = AvatarRadialProfile.outline(of: shape)
            // 取样的 120 个方向，再加 720 个错开的方向。
            let samples: [Double] = (0..<AvatarRadialProfile.sampleCount).map(AvatarRadialProfile.angle(at:))
            let between: [Double] = (0..<720).map { i in
                let step = 2 * Double.pi / 720
                return -Double.pi / 2 + (Double(i) + 0.37) * step
            }
            let angles = samples + between
            var bad: [(angle: Double, hits: [Double])] = []
            for angle in angles {
                let hits = AvatarRadialProfile.hits(on: outline, angle: angle).sorted()
                var distinct: [Double] = []
                for hit in hits where distinct.last.map({ hit - $0 > 1e-6 }) ?? true {
                    distinct.append(hit)
                }
                if distinct.count != 1 { bad.append((angle, distinct)) }
            }
            #expect(bad.isEmpty, "\(shape): \(bad.prefix(3))")
        }
    }

    @Test("身体贴着原来的形状：穿过 120 个点的平滑曲线和轮廓相互离得不到 0.005")
    func bodyFollowsOutline() {
        for shape in AvatarShape.allCases {
            let outline = AvatarRadialProfile.outline(of: shape)
            let body = BotinFaceShape.outlines(
                radii: AvatarRadialProfile.radii(of: shape), faceY: 0.5, pose: BotinFaceLife.restPose
            ).body
            // 身体上的点离原来的轮廓（最偏的在两个采样点中间，曲线上的点都查），原来的轮廓上的点离身体（凹进去的角）。
            let exact = Polygon(outline)
            let radial = Polygon(body)
            let away = body.map { abs(exact.signedDistance(to: $0)) }.max() ?? 1
            let back = outline.map { abs(radial.signedDistance(to: $0)) }.max() ?? 1
            #expect(away < 0.005 && back < 0.005, "\(shape): \(away) \(back)")
        }
    }

    @Test("眼睛在身体里面：每种形状、看到最远的九个方向，离边至少 0.05")
    func eyesInsideBody() {
        for shape in AvatarShape.allCases {
            let radii = AvatarRadialProfile.radii(of: shape)
            let faceY = BotinFaceLayout.faceY(of: shape)
            let margin = eyeMargin(radii: radii, faceY: faceY, bodyStride: 4)
            #expect(margin >= 0.05, "\(shape): \(margin)")
        }
    }

    @Test("换形状的半路上眼睛也在身体里面：210 对形状 × 五个时刻（含弹簧冲过头），离边至少 0.03（冲过头 12% 时 0.025）")
    func eyesInsideWhileMorphing() {
        // 1.04：`BotinFace.morph`（snappy，回弹 0.15 + 0.12，阻尼比约 0.73）自己冲过头约 3.5%；1.12：动画半路被打断、
        // 带着速度换目标时冲得更远的情况。眼睛的大小、位置是定好的，1.12 时最紧的一对（圆角方形 → 四角星）余量约
        // 0.0285，所以那一档只要求 0.025（在 48pt 的头像上也还有 1.2pt）。
        let thresholds: [(t: Double, margin: Double)] = [
            (0.25, 0.03), (0.5, 0.03), (0.75, 0.03), (1.04, 0.03), (1.12, 0.025),
        ]
        var tight: [String] = []
        for from in AvatarShape.allCases {
            for to in AvatarShape.allCases where to != from {
                let a = AvatarRadialProfile.radii(of: from)
                let b = AvatarRadialProfile.radii(of: to)
                let fa = BotinFaceLayout.faceY(of: from)
                let fb = BotinFaceLayout.faceY(of: to)
                for (t, required) in thresholds {
                    // 和 SwiftUI 插值一样：起点 + (终点 - 起点) × 进度。
                    var delta = b - a
                    delta.scale(by: t)
                    let margin = eyeMargin(radii: a + delta, faceY: fa + (fb - fa) * t, bodyStride: 8)
                    if margin < required { tight.append("\(from)→\(to) t=\(t): \(margin)") }
                }
            }
        }
        #expect(tight.isEmpty, "\(tight.prefix(10))")
    }

    @Test("脸的样子：看向挪眼睛，往一边看那边的眼睛窄一点，眨眼压扁；坏值当不动")
    func eyeLayout() {
        let rest = BotinFaceLayout.eyes(faceY: 0.47, pose: BotinFaceLife.restPose)
        #expect(rest.count == 2)
        #expect(close(rest[0], centerX: 0.395, centerY: 0.47, width: 0.10, height: 0.16))
        #expect(close(rest[1], centerX: 0.605, centerY: 0.47, width: 0.10, height: 0.16))
        // 往右上看到最远：都往右挪 0.04、往上 0.025，右眼窄 15%。
        let upRight = BotinFaceLayout.eyes(faceY: 0.5, pose: Pose(gazeX: 1, gazeY: -1, lid: 1))
        #expect(close(upRight[0], centerX: 0.435, centerY: 0.475, width: 0.10, height: 0.16))
        #expect(close(upRight[1], centerX: 0.645, centerY: 0.475, width: 0.085, height: 0.16))
        // 往左下看一半：往下最多 0.02。
        let downLeft = BotinFaceLayout.eyes(faceY: 0.5, pose: Pose(gazeX: -0.5, gazeY: 1, lid: 0.5))
        #expect(close(downLeft[0], centerX: 0.375, centerY: 0.52, width: 0.0925, height: 0.08))
        #expect(close(downLeft[1], centerX: 0.585, centerY: 0.52, width: 0.10, height: 0.08))
        // 超出范围的夹住，NaN 当不动。
        let clamped = BotinFaceLayout.eyes(faceY: 0.5, pose: Pose(gazeX: 5, gazeY: .nan, lid: -1))
        #expect(close(clamped[1], centerX: 0.645, centerY: 0.5, width: 0.085, height: 0.016))
        let nan = BotinFaceLayout.eyes(faceY: 0.5, pose: Pose(gazeX: .nan, gazeY: 0, lid: .nan))
        #expect(nan == BotinFaceLayout.eyes(faceY: 0.5, pose: BotinFaceLife.restPose))
        // 画出来的是椭圆：四段贝塞尔上的点都在椭圆上（误差不到半径的 0.1%）。
        for eye in upRight + downLeft {
            let points = eyeOutline(eye)
            // 起点 + 四段 × 每段 16 个点（最后一个回到起点）。
            #expect(points.count == 65)
            let worst =
                points.map { p in
                    let u = (Double(p.x) - eye.centerX) / (eye.width / 2)
                    let v = (Double(p.y) - eye.centerY) / (eye.height / 2)
                    return abs((u * u + v * v).squareRoot() - 1)
                }.max() ?? 1
            #expect(worst < 0.001, "\(eye): \(worst)")
        }
        // 每种形状的脸都在中间偏上一点到偏下的位置。
        for shape in AvatarShape.allCases {
            let faceY = BotinFaceLayout.faceY(of: shape)
            #expect(faceY >= 0.44 && faceY <= 0.6, "\(shape)")
        }
    }

    @Test("变形的动画数据：空数组是零，在哪边都行；长度不一样时缺的当 0")
    func radiiArithmetic() {
        let a = AvatarRadii([0.5, 0.25, 0.125])
        let b = AvatarRadii([0.1, 0.2])
        let zero = AvatarRadii.zero
        #expect(zero.values.isEmpty)
        #expect(a + zero == a && zero + a == a)
        #expect(a - zero == a)
        #expect((zero - a).values == [-0.5, -0.25, -0.125])
        #expect(a - a == zero && zero == a - a)
        #expect((a + b).values == [0.6, 0.45, 0.125])
        #expect((b + a).values == (a + b).values)
        #expect((b - a).values == [0.1 - 0.5, 0.2 - 0.25, -0.125])
        #expect((a + b) - b == a)
        #expect(AvatarRadii([1, 0, 0]) == AvatarRadii([1]))
        #expect(AvatarRadii([1, 0, 0.001]) != AvatarRadii([1]))
        var c = zero
        c += a
        #expect(c == a)
        c -= zero
        #expect(c == a)
        c -= a
        #expect(c == zero)
        var d = b
        d += a
        #expect(d.values == (a + b).values)
        var e = zero
        e -= b
        #expect(e.values == [-0.1, -0.2])
        var doubled = a
        doubled.scale(by: 2)
        #expect(doubled == a + a)
        var scaledZero = zero
        scaledZero.scale(by: 3)
        #expect(scaledZero == zero && scaledZero.values.isEmpty)
        #expect(zero.magnitudeSquared == 0)
        #expect(AvatarRadii([3, 4]).magnitudeSquared == 25)
        #expect(a[5] == 0 && a[0] == 0.5)
        // 和脸的高度拼在一起（`BotinFaceShape.animatableData`）。
        let pair = AnimatablePair(a, 0.5) - AnimatablePair(AvatarRadii.zero, 0.25)
        #expect(pair.first == a && pair.second == 0.25)
        #expect(AnimatablePair<AvatarRadii, Double>.zero.first == zero)
        var shape = BotinFaceShape(shape: .circle)
        let star = BotinFaceShape(shape: .star)
        shape.animatableData = star.animatableData
        #expect(shape.radii == star.radii && shape.faceY == BotinFaceLayout.faceY(of: .star))
    }

    @Test("时间线：先给开始时刻，一直往后走过 20 多个窗口；窗口里帧距不超过 frameInterval，正好停在窗口的结尾；窗口之间不给")
    func schedule() {
        for (name, interval) in [("周报助手", 1.0 / 60), ("翻译", 1.0 / 30)] {
            let life = BotinFaceLife(name: name)
            let schedule = BotinFaceSchedule(life: life, frameInterval: interval)
            let start = 815_000_000.5
            // 开始以后的前 25 个窗口（一个接一个找）。
            var windows: [ClosedRange<TimeInterval>] = []
            var cursor = start
            while windows.count < 25 {
                let window = life.nextActiveWindow(after: cursor)
                windows.append(window)
                cursor = window.upperBound
            }
            let end = windows[windows.count - 1].upperBound
            var dates: [TimeInterval] = []
            var iterator = schedule.entries(from: Date(timeIntervalSinceReferenceDate: start), mode: .normal)
                .makeIterator()
            while dates.count < 20_000, let date = iterator.next() {
                dates.append(date.timeIntervalSinceReferenceDate)
                if date.timeIntervalSinceReferenceDate >= end { break }
            }
            #expect(dates.first == start)
            #expect(dates.last == end, "\(name): 走不到第 25 个窗口的结尾")
            #expect(dates.count < 25 * 20, "\(name): \(dates.count)")
            #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
            let given = Set(dates)
            for (i, window) in windows.enumerated() where window.lowerBound > start {
                #expect(given.contains(window.upperBound), "\(name) \(window)")
                // 开头要么给了，要么在前一个窗口里（重叠的窗口接着逐帧画）。
                let covered = windows[..<i].contains { $0.contains(window.lowerBound) }
                #expect(given.contains(window.lowerBound) || covered, "\(name) \(window)")
            }
            var problems: [String] = []
            for (previous, date) in zip(dates, dates.dropFirst()) {
                // 每个时刻都在一个窗口里（或者正是窗口的结尾）。
                if life.nextActiveWindow(after: date - 1e-6).lowerBound > date { problems.append("窗口外 \(date)") }
                // 隔得比一帧长的只能是跳到下一个窗口的开头。
                if date - previous > interval + 1e-9 {
                    let next = life.nextActiveWindow(after: previous)
                    if next.lowerBound != date || next.lowerBound <= previous {
                        problems.append("跳 \(previous)→\(date)")
                    }
                }
            }
            #expect(problems.isEmpty, "\(name): \(problems.prefix(5))")
            // 开始时刻在窗口里也一样：先给开始时刻，接着逐帧。
            let inside = windows[3].lowerBound + 0.05
            var fromInside = schedule.entries(from: Date(timeIntervalSinceReferenceDate: inside), mode: .normal)
                .makeIterator()
            let first = fromInside.next()?.timeIntervalSinceReferenceDate
            let second = fromInside.next()?.timeIntervalSinceReferenceDate
            #expect(first == inside)
            #expect(second.map { $0 > inside && $0 - inside <= interval + 1e-9 } == true)
        }
    }

    @Test("时间线的低频模式只给一个时刻：开始时刻，在窗口里时给窗口的结尾")
    func scheduleLowFrequency() {
        let life = BotinFaceLife(name: "周报助手")
        let schedule = BotinFaceSchedule(life: life, frameInterval: 1.0 / 60)
        // 找一个前面至少空出 0.01 秒的窗口。
        var window = life.nextActiveWindow(after: 815_000_000)
        while life.nextActiveWindow(after: window.lowerBound - 0.01).lowerBound != window.lowerBound {
            window = life.nextActiveWindow(after: window.upperBound)
        }
        let calm = window.lowerBound - 0.01
        let calmDates = Array(schedule.entries(from: Date(timeIntervalSinceReferenceDate: calm), mode: .lowFrequency))
        #expect(calmDates.map(\.timeIntervalSinceReferenceDate) == [calm])
        let busy = window.lowerBound + 0.05
        let busyDates = Array(schedule.entries(from: Date(timeIntervalSinceReferenceDate: busy), mode: .lowFrequency))
        #expect(busyDates.count == 1)
        let resting = busyDates.first?.timeIntervalSinceReferenceDate ?? 0
        #expect(resting >= window.upperBound)
        // 给的时刻不在任何窗口里：眼睛睁着、不在半路。
        #expect(life.nextActiveWindow(after: resting).lowerBound > resting)
        #expect(life.pose(at: resting).lid == 1)
    }

    @Test("时间线：太远、不是有限数的时间给完开始时刻就结束，不原地打转；帧率按头像大小")
    func scheduleEdges() {
        let schedule = BotinFaceSchedule(life: BotinFaceLife(name: "Pi"), frameInterval: 1.0 / 60)
        for start in [1e13, -1e13, Double.infinity] {
            let dates = Array(
                schedule.entries(from: Date(timeIntervalSinceReferenceDate: start), mode: .normal).prefix(5))
            #expect(dates.count == 1, "\(start)")
        }
        // 帧距不是正的有限数时按 1/60 秒。
        #expect(BotinFaceSchedule(life: BotinFaceLife(seed: 1), frameInterval: 0).frameInterval == 1.0 / 60)
        #expect(BotinFaceSchedule(life: BotinFaceLife(seed: 1), frameInterval: .nan).frameInterval == 1.0 / 60)
        #expect(BotinFaceSchedule.frameInterval(forSide: Metrics.Avatar.title) == 1.0 / 30)
        #expect(BotinFaceSchedule.frameInterval(forSide: Metrics.Avatar.list) == 1.0 / 30)
        #expect(BotinFaceSchedule.frameInterval(forSide: 60) == 1.0 / 60)
        #expect(BotinFaceSchedule.frameInterval(forSide: Metrics.Avatar.profile) == 1.0 / 60)
        // 减弱动态效果、截图开关：有一个关着就不动。
        #expect(BotinFace.motionAllowed(reduceMotion: false, botinFaceMotion: true))
        #expect(!BotinFace.motionAllowed(reduceMotion: true, botinFaceMotion: true))
        #expect(!BotinFace.motionAllowed(reduceMotion: false, botinFaceMotion: false))
    }

    @Test("各种形状、颜色、尺寸都画得出来（动的、不动的、关了动效的）")
    func renders() {
        for shape in AvatarShape.allCases {
            renderInBothAppearances(
                BotinFace(name: "周报助手", appearance: InstanceAppearance(shape: shape), size: Metrics.Avatar.list))
            renderInBothAppearances(
                BotinFace(
                    name: "翻译", appearance: InstanceAppearance(shape: shape, color: .graphite), size: 32, live: false))
        }
        for color in AvatarColor.allCases {
            renderInBothAppearances(
                BotinFace(name: "Pi", appearance: InstanceAppearance(shape: .cloud, color: color), size: 120)
                    .environment(\.botinFaceMotion, false))
        }
        renderInBothAppearances(BotinFace(name: "", appearance: .default, size: Metrics.Avatar.title))
        // 新建表单的预览：节奏是给的，不按名字算。
        renderInBothAppearances(
            BotinFace(name: "写作助手", appearance: .default, size: 120, life: BotinFaceLife(seed: 7)))
    }

    // MARK: - 几何工具

    /// 眼睛（九个看到最远的方向，每只眼睛 16 个点）离身体（每 `bodyStride` 个点取一个连成多边形）的边最近多远；
    /// 负的是跑到身体外面了。
    private func eyeMargin(radii: AvatarRadii, faceY: Double, bodyStride: Int) -> Double {
        let body = Polygon(
            every(bodyStride, of: BotinFaceShape.outlines(radii: radii, faceY: faceY, pose: .init()).body))
        var margin = Double.infinity
        for pose in gazeExtremes {
            for eye in BotinFaceLayout.eyes(faceY: faceY, pose: pose) {
                for point in every(4, of: eyeOutline(eye)) {
                    margin = min(margin, body.signedDistance(to: point))
                }
            }
        }
        return margin
    }

    private func eyeOutline(_ eye: BotinFaceLayout.Eye) -> [CGPoint] {
        var builder = AvatarPathBuilder(recordsOutline: true)
        BotinFaceShape.drawEye(eye, into: &builder)
        return builder.outline
    }

    private func every(_ stride: Int, of points: [CGPoint]) -> [CGPoint] {
        Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
    }

    private func close(
        _ eye: BotinFaceLayout.Eye, centerX: Double, centerY: Double, width: Double, height: Double
    ) -> Bool {
        abs(eye.centerX - centerX) < 1e-9 && abs(eye.centerY - centerY) < 1e-9 && abs(eye.width - width) < 1e-9
            && abs(eye.height - height) < 1e-9
    }
}

/// 首尾相连的多边形：点到它的边的距离，在里面为正、外面为负（奇偶规则判断里外）。
private struct Polygon {
    let xs: [Double]
    let ys: [Double]

    init(_ points: [CGPoint]) {
        xs = points.map { Double($0.x) }
        ys = points.map { Double($0.y) }
    }

    func signedDistance(to point: CGPoint) -> Double {
        let px = Double(point.x)
        let py = Double(point.y)
        var nearest = Double.infinity
        var inside = false
        xs.withUnsafeBufferPointer { x in
            ys.withUnsafeBufferPointer { y in
                var j = x.count - 1
                for i in 0..<x.count {
                    let ax = x[j]
                    let ay = y[j]
                    let ex = x[i] - ax
                    let ey = y[i] - ay
                    // 向右的水平射线穿过这条边：里外翻一次。
                    if (ay > py) != (y[i] > py), ax + (py - ay) * ex / ey > px {
                        inside.toggle()
                    }
                    let length = ex * ex + ey * ey
                    let u = length > 0 ? min(1, max(0, ((px - ax) * ex + (py - ay) * ey) / length)) : 0
                    let dx = ax + u * ex - px
                    let dy = ay + u * ey - py
                    nearest = min(nearest, dx * dx + dy * dy)
                    j = i
                }
            }
        }
        return inside ? nearest.squareRoot() : -nearest.squareRoot()
    }
}
