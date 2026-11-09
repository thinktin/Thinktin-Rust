import Foundation
import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// Botin 头像的脸（docs/ios-ui-redesign.md 4.4.4）：径向轮廓贴着原来的形状、眼睛在身体里面（换形状的半路上、跳起来、
/// 歪头、笑眼、睁大眼、在等用户时连跳的时候都是）、身体和眼睛一起变换、笑眼的样子、变形的动画数据、只在动的时候重画的
/// 时间线（在跑的、在等用户的、只有反应的）、状态从角标推、各种形状和颜色都画得出来。
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

    @Test("换形状的半路上笑着也在里面（在跑的预览会在变形时笑、跳）：210 对形状 × 三个时刻，笑眼看向够得着的 16 个方向和正前方，离边至少 0.03（冲过头 12% 时 0.02）")
    func smilingEyesInsideWhileMorphing() {
        // 在跑的时候转眼的落点在 x² + (y / 0.8)² ≤ 1 里（`BotinFaceLife.glanceTarget`），笑的小动作、反应不改看向。
        // 冲过头 12%（变形动画半路被打断、带着速度换目标）又正好笑到最满、往四角星窄的那边看时最紧（圆角方形 → 四角星
        // 约 0.0204，48pt 的头像上约 1pt），那一档按 0.02 查；平常的回弹（1.04）照样 0.03。为了快，身体取 120 个采样点
        // 连成的多边形、每只眼睛取 48 个点。
        let smiling =
            (0..<16).map { k -> Pose in
                let angle = 2 * Double.pi * Double(k) / 16
                return Pose(gazeX: cos(angle), gazeY: 0.8 * sin(angle), smile: 1)
            } + [Pose(smile: 1)]
        let eyes = smiling.map { pose in
            BotinFaceLayout.eyes(faceY: 0, pose: pose).flatMap { every(16, of: eyeOutline($0)) }
        }
        var tight: [String] = []
        for from in AvatarShape.allCases {
            for to in AvatarShape.allCases where to != from {
                let a = AvatarRadialProfile.radii(of: from)
                let b = AvatarRadialProfile.radii(of: to)
                let fa = BotinFaceLayout.faceY(of: from)
                let fb = BotinFaceLayout.faceY(of: to)
                for (t, required) in [(0.5, 0.03), (1.04, 0.03), (1.12, 0.02)] {
                    var delta = b - a
                    delta.scale(by: t)
                    let faceY = fa + (fb - fa) * t
                    let body = Polygon(
                        every(16, of: BotinFaceShape.outlines(radii: a + delta, faceY: faceY, pose: .init()).body))
                    let margin =
                        eyes.joined().map { body.signedDistance(to: CGPoint(x: $0.x, y: $0.y + faceY)) }.min() ?? -1
                    if margin < required { tight.append("\(from)→\(to) t=\(t): \(margin)") }
                }
            }
        }
        #expect(tight.isEmpty, "\(tight.prefix(10))")
    }

    @Test(
        "眼睛在身体里面（模型做得出来的每个样子）：15 种形状 × 在跑、在等用户时各 20 秒的每一帧、每个小动作和两种反应从头到尾（从看到最远的各个方向起，连跳和反应也从睁大眼睛往上看起）、不动的表情、几次反应叠到头，离边至少 0.03；身体挪动不超过 0.08，伸缩在 0.88 到 1.10"
    )
    func eyesInsideUnderEveryPose() {
        let poses = Self.reachablePoses()
        #expect(poses.count > 3_000)
        let outOfRange = poses.filter { pose in
            abs(pose.bodyOffsetY) > 0.08 || !(0.88...1.10).contains(pose.squashX)
                || !(0.88...1.10).contains(pose.squashY) || abs(pose.tilt) > 0.15
        }
        #expect(outOfRange.isEmpty, "\(outOfRange.prefix(3))")
        // 眼睛的点和身体的变换只和样子有关；脸的高度只把眼睛整个往下挪，所以先按高度 0 算好，每种形状再挪过去。
        // 身体和眼睛一起做同一个仿射变换，变换后的余量至少是变换前的 `minimumScale` 倍（歪、挪不改距离，伸缩取小的）。
        let eyeSets: [(points: [CGPoint], scale: Double)] = poses.map { pose in
            let clamped = pose.clamped()
            let points = BotinFaceLayout.eyes(faceY: 0, pose: clamped).flatMap { eye in
                every(eye.smile > 0 ? 8 : 2, of: eyeOutline(eye))
            }
            return (points, BotinFaceShape.transform(body: [], pose: clamped).minimumScale)
        }
        var report: [String] = []
        for shape in AvatarShape.allCases {
            let faceY = BotinFaceLayout.faceY(of: shape)
            let radii = AvatarRadialProfile.radii(of: shape)
            let body = Polygon(every(4, of: BotinFaceShape.outlines(radii: radii, faceY: faceY, pose: .init()).body))
            let grid = DistanceGrid(body, x: 0.26...0.74, y: (faceY - 0.18)...(faceY + 0.15), step: 0.005)
            var worst = (margin: Double.infinity, pose: 0)
            for (index, set) in eyeSets.enumerated() {
                for point in set.points {
                    let p = CGPoint(x: point.x, y: point.y + faceY)
                    // 格子给的是下界；不够时按多边形算准的。
                    var distance = grid.lowerBound(at: p)
                    if distance * set.scale < 0.03 { distance = body.signedDistance(to: p) }
                    if distance * set.scale < worst.margin { worst = (distance * set.scale, index) }
                }
            }
            if worst.margin < 0.03 { report.append("\(shape): \(worst.margin) \(poses[worst.pose])") }
        }
        #expect(report.isEmpty, "\(report)")
    }

    @Test("身体和眼睛一起变：伸缩以身体最下面的中点为准、歪是顺时针、挪是上下；跳到最高、蹲下、歪头、笑的时候变换后的眼睛也在变换后的身体里面")
    func bodyTransform() {
        let identity = BotinBodyTransform.identity
        #expect(identity.isIdentity && identity.minimumScale == 1)
        let point = CGPoint(x: 0.123_456_7, y: 0.765_432_1)
        #expect(identity.apply(point) == point)
        // 蹲下：脚底（身体最下面的中点）不动，头顶往下，横着撑开。
        let crouch = BotinBodyTransform(pose: Pose(squashX: 1.08, squashY: 0.9), bottom: 0.97)
        #expect(!crouch.isIdentity && abs(crouch.minimumScale - 0.9) < 1e-12)
        #expect(distance(crouch.apply(CGPoint(x: 0.5, y: 0.97)), CGPoint(x: 0.5, y: 0.97)) < 1e-12)
        #expect(distance(crouch.apply(CGPoint(x: 0.5, y: 0.03)), CGPoint(x: 0.5, y: 0.97 - 0.94 * 0.9)) < 1e-12)
        #expect(distance(crouch.apply(CGPoint(x: 0.6, y: 0.97)), CGPoint(x: 0.608, y: 0.97)) < 1e-12)
        // 歪：正的顺时针（y 向下时右边的点往下走），绕 (0.5, 0.5)。
        let tilt = BotinBodyTransform(pose: Pose(tilt: 0.1), bottom: 1)
        let right = tilt.apply(CGPoint(x: 1, y: 0.5))
        #expect(
            abs(Double(right.x) - (0.5 + 0.5 * cos(0.1))) < 1e-12
                && abs(Double(right.y) - (0.5 + 0.5 * sin(0.1))) < 1e-12)
        #expect(distance(tilt.apply(CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 0.5, y: 0.5)) < 1e-12)
        // 挪：负的往上。
        let up = BotinBodyTransform(pose: Pose(bodyOffsetY: -0.075), bottom: 1)
        #expect(distance(up.apply(CGPoint(x: 0.3, y: 0.5)), CGPoint(x: 0.3, y: 0.425)) < 1e-12)
        // 画出来的身体就是不动的身体变换过去（每个点都是）；基准是那一刻身体最下面的点。
        let hopTop = Pose().adding(.hop, at: 0.26)
        let poses = [
            hopTop, Pose().adding(.hop, at: 0.10), Pose(gazeX: 1, gazeY: -0.8).adding(.tiltRight, at: 0.6),
            Pose(gazeX: -1, gazeY: -0.8).adding(.tap, at: 0.3), Pose(gazeY: 0.8).adding(.nod, at: 0.18),
            BotinFaceLife.restPose(for: .waiting).adding(.happy, at: 0.5),
            BotinFaceLife.restPose(for: .waiting).adding(.doubleHop, at: 0.34 + 0.045),
        ]
        for shape in AvatarShape.allCases {
            let radii = AvatarRadialProfile.radii(of: shape)
            let faceY = BotinFaceLayout.faceY(of: shape)
            let restBody = BotinFaceShape.bodyPoints(radii)
            let bottom = restBody.map { Double($0.y) }.max() ?? 1
            for pose in poses {
                let transform = BotinBodyTransform(pose: pose, bottom: bottom)
                let drawn = BotinFaceShape.outlines(radii: radii, faceY: faceY, pose: pose)
                var expected = AvatarPathBuilder(recordsOutline: true)
                expected.smooth(restBody.map(transform.apply))
                #expect(zip(drawn.body, expected.outline).allSatisfy { distance($0, $1) < 1e-9 }, "\(shape)")
                let body = Polygon(every(4, of: drawn.body))
                let margin = drawn.eyes.flatMap { $0 }.map { body.signedDistance(to: $0) }.min() ?? -1
                #expect(margin >= 0.03, "\(shape) \(pose): \(margin)")
            }
            // 跳到最高时整个身体往上挪了 0.075。
            let top = BotinFaceShape.outlines(radii: radii, faceY: faceY, pose: hopTop).body
            let restTop = BotinFaceShape.outlines(radii: radii, faceY: faceY, pose: .init()).body
            let lift = (restTop.map { Double($0.y) }.min() ?? 0) - (top.map { Double($0.y) }.min() ?? 0)
            #expect(abs(lift - 0.075) < 1e-6, "\(shape): \(lift)")
        }
    }

    @Test(
        "头顶最多冒出方框上沿 0.10（单位边长）：15 种形状 × 每个小动作和两种反应从头到尾、在跑时 20 秒的每一帧、连着点几下叠在一起、歪着头时被点；只跳一下时几乎不用往回挪（最多削掉 0.002），挪回来是连续的"
    )
    func liftStaysWithinLimit() {
        let lift = BotinFaceLife.Limits.lift
        let life = BotinFaceLife(name: "周报助手")
        let start = 815_000_000.0
        var single = Set<Pose>()
        for gesture in BotinFaceGesture.allCases {
            for u in stride(from: 0.0, through: gesture.duration, by: 1.0 / 60) {
                single.insert(Pose().adding(gesture, at: u))
            }
        }
        for i in 0..<(20 * 60) {
            single.insert(life.pose(at: start + Double(i) / 60, mood: .active))
            single.insert(life.pose(at: start + Double(i) / 60, mood: .waiting))
        }
        // 连着点（按时间顺序，查挪回来连续）：两下隔 0.05、0.15、0.2 秒，四下各隔 0.05 秒（`BotinFaceReaction.limit`）；
        // 在跑的头像正歪着头时被点了（歪到一半、歪着、回正的时候）。
        var sequences: [[Pose]] = []
        for offsets in [[0, 0.05], [0, 0.15], [0, 0.2], [0, 0.05, 0.1, 0.15]] {
            let reactions = offsets.map { BotinFaceReaction(.tap, start: start + $0) }
            sequences.append(
                (0..<75).map { life.pose(at: start + Double($0) / 60, mood: .resting, reactions: reactions) })
        }
        for gesture in [BotinFaceGesture.tiltLeft, .tiltRight] {
            for tapAt in stride(from: 0.0, through: 0.8, by: 0.2) {
                sequences.append(
                    stride(from: 0.0, through: 0.9, by: 1.0 / 60).map {
                        Pose().adding(gesture, at: tapAt + $0).adding(.tap, at: $0)
                    })
            }
        }
        var report: [String] = []
        var trimmed = 0.0
        var raised = 0.0
        for shape in AvatarShape.allCases {
            let radii = AvatarRadialProfile.radii(of: shape)
            let faceY = BotinFaceLayout.faceY(of: shape)
            let rest = BotinFaceShape.bodyPoints(radii)
            let bottom = rest.map { Double($0.y) }.max() ?? 1
            func top(_ pose: Pose) -> Double {
                BotinFaceShape.outlines(radii: radii, faceY: faceY, pose: pose).body.map { Double($0.y) }.min() ?? 0
            }
            // 画出来的曲线在相邻两点之间最多鼓出 0.005（`bodyFollowsOutline`）。
            for pose in single where top(pose) < -lift - 0.005 {
                report.append("\(shape) \(pose): \(top(pose))")
            }
            func rawTop(_ pose: Pose) -> Double {
                let raw = BotinBodyTransform(pose: pose.clamped(), bottom: bottom)
                return rest.map { Double(raw.apply($0).y) }.min() ?? 0
            }
            for sequence in sequences {
                var previous: (drawn: Double, raw: Double)?
                for pose in sequence {
                    let current = (drawn: top(pose), raw: rawTop(pose))
                    if current.drawn < -lift - 0.005 { report.append("\(shape) \(pose): \(current.drawn)") }
                    // 挪回来不会一跳：两帧之间头顶挪得不比不挪时多（曲线上取的点和身体的点差一点，留 0.005）。
                    if let previous, abs(current.drawn - previous.drawn) > abs(current.raw - previous.raw) + 0.005 {
                        report.append("\(shape) 跳 \(previous)→\(current)")
                    }
                    previous = current
                    raised = max(raised, -current.raw)
                }
            }
            for pose in single {
                trimmed = max(trimmed, -lift - rawTop(pose))
            }
        }
        #expect(report.isEmpty, "\(report.prefix(3))")
        // 只跳一下（随机的、点一下）：没挪的时候头顶最高约 0.102，挪回来的不到 0.003。
        #expect(trimmed > 0 && trimmed < 0.003, "\(trimmed)")
        // 不挪回来的话，叠在一起时会冒出 0.14 以上（所以要挪）。
        #expect(raised > 0.14, "\(raised)")
    }

    @Test("笑眼：一样宽，上边是椭圆的上半边、整只往上提 0.15 倍眼睛高，下边是上边压到 0.55 倍；中间的按点插值；眨眼一起压扁；睁大以眼睛中心为准")
    func smileEyes() {
        typealias Eye = BotinFaceLayout.Eye
        let happy = Eye(centerX: 0.4, centerY: 0.5, width: 0.1, height: 0.16, smile: 1)
        let points = BotinFaceLayout.smilePoints(happy)
        #expect(points.count == 48)
        let lift = 0.15 * 0.16
        // 最右、最左（两头接上，在提过的中线上）；最上（椭圆的顶，提过）；最下边的中间（上边压到 0.55 倍）。
        #expect(distance(points[0], CGPoint(x: 0.45, y: 0.5 - lift)) < 1e-12)
        #expect(distance(points[24], CGPoint(x: 0.35, y: 0.5 - lift)) < 1e-12)
        #expect(distance(points[36], CGPoint(x: 0.4, y: 0.5 - 0.08 - lift)) < 1e-12)
        #expect(distance(points[12], CGPoint(x: 0.4, y: 0.5 - 0.55 * 0.08 - lift)) < 1e-12)
        let xs = points.map { Double($0.x) }
        #expect(abs((xs.max() ?? 0) - (xs.min() ?? 0) - 0.1) < 1e-12)
        // 上半边的点就是椭圆上的（提过）；下半边的每个点都在同一个 x 处的上边下面（中间厚、两头细）。
        for i in 25..<48 {
            let angle = 2 * Double.pi * Double(i) / 48
            #expect(abs(Double(points[i].y) - (0.5 + 0.08 * sin(angle) - lift)) < 1e-12)
        }
        for i in 1..<24 {
            let upper = points[48 - i]
            #expect(abs(upper.x - points[i].x) < 1e-12)
            let thickness = Double(points[i].y - upper.y)
            #expect(thickness > 0 && abs(thickness - 0.45 * 0.08 * sin(2 * Double.pi * Double(i) / 48)) < 1e-12)
        }
        // 半笑：同一个角度上椭圆和“∩”的中点。
        var half = happy
        half.smile = 0.5
        var plain = happy
        plain.smile = 0
        let halfPoints = BotinFaceLayout.smilePoints(half)
        let plainPoints = BotinFaceLayout.smilePoints(plain)
        for i in 0..<48 {
            let mid = CGPoint(x: (plainPoints[i].x + points[i].x) / 2, y: (plainPoints[i].y + points[i].y) / 2)
            #expect(distance(halfPoints[i], mid) < 1e-12)
        }
        // 不笑时就在椭圆上。
        for (i, p) in plainPoints.enumerated() {
            let angle = 2 * Double.pi * Double(i) / 48
            #expect(distance(p, CGPoint(x: 0.4 + 0.05 * cos(angle), y: 0.5 + 0.08 * sin(angle))) < 1e-12)
        }
        // 姿势里的笑、睁大、眨眼。
        let wide = BotinFaceLayout.eyes(faceY: 0.5, pose: Pose(eyeScale: 1.12, smile: 0.4))
        #expect(close(wide[0], centerX: 0.395, centerY: 0.5, width: 0.112, height: 0.16 * 1.12))
        #expect(wide.allSatisfy { $0.smile == 0.4 })
        let blinking = BotinFaceLayout.eyes(faceY: 0.5, pose: Pose(lid: 0.5, smile: 1))[1]
        #expect(close(blinking, centerX: 0.605, centerY: 0.5, width: 0.1, height: 0.08))
        let squashed = BotinFaceLayout.smilePoints(blinking)
        #expect(abs(Double(squashed[36].y) - (0.5 - 0.04 - 0.15 * 0.08)) < 1e-12)
        // 笑的时候画的是穿过这些点的平滑曲线（48 段），不笑时是四段的椭圆。
        #expect(eyeOutline(blinking).count == 48 * 16 + 1)
        #expect(eyeOutline(BotinFaceLayout.eyes(faceY: 0.5, pose: Pose())[0]).count == 65)
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

    @Test("时间线（在跑的、在等用户的，也有刚变成这样的）：先给开始时刻，一直往后走过 20 多个窗口；窗口里帧距不超过 frameInterval，正好停在窗口的结尾；窗口之间不给；变成这样以前开始的窗口不给")
    func schedule() {
        let start = 815_000_000.5
        // 一直在跑、在等的，和开始以后 0.37 秒才变成在跑、在等的（`since`：那以前开始的窗口不算）。
        let cases: [(name: String, interval: TimeInterval, since: TimeInterval, mood: BotinFaceMood)] = [
            ("周报助手", 1.0 / 60, -.infinity, .active), ("翻译", 1.0 / 30, -.infinity, .active),
            ("周报助手", 1.0 / 60, start + 0.37, .active), ("盯盘", 1.0 / 30, -.infinity, .waiting),
            ("周报助手", 1.0 / 60, start + 0.37, .waiting),
        ]
        for (name, interval, since, mood) in cases {
            let life = BotinFaceLife(name: name)
            let schedule = BotinFaceSchedule(life: life, mood: mood, since: since, frameInterval: interval)
            // 开始以后的前 25 个窗口（一个接一个找）。
            var windows: [ClosedRange<TimeInterval>] = []
            var cursor = start
            while windows.count < 25 {
                let window = life.nextActiveWindow(after: cursor, mood: mood, since: since)
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
            #expect(windows.allSatisfy { $0.lowerBound >= since }, "\(name) \(since)")
            // 每个窗口最多 长度 / 帧距 + 2 帧（开头、结尾），窗口之间一帧都不给。
            let budget = windows.reduce(1) { $0 + Int(($1.upperBound - $1.lowerBound) / interval) + 2 }
            #expect(dates.count <= budget, "\(name): \(dates.count) > \(budget)")
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
                if life.nextActiveWindow(after: date - 1e-6, mood: mood, since: since).lowerBound > date {
                    problems.append("窗口外 \(date)")
                }
                // 隔得比一帧长的只能是跳到下一个窗口的开头。
                if date - previous > interval + 1e-9 {
                    let next = life.nextActiveWindow(after: previous, mood: mood, since: since)
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

    @Test("时间线（只有反应）：不在跑、不在等的头像只在反应的窗口里逐帧给、正好停在结尾，做完就不再给；在跑的头像反应也排进去")
    func scheduleWithReactions() {
        let life = BotinFaceLife(name: "周报助手")
        let start = 815_000_000.25
        // 点了一下，0.3 秒后又挑了形状（笑一下，和点一下的叠在一起），5 秒后又点了一下。
        let reactions = [
            BotinFaceReaction(.tap, start: start), BotinFaceReaction(.happy, start: start + 0.3),
            BotinFaceReaction(.tap, start: start + 5),
        ]
        let ends = reactions.map(\.end)
        let interval = 1.0 / 60
        for mood in [BotinFaceMood.resting, .sleeping, .still] {
            // 没有反应：只给开始时刻。
            let calm = BotinFaceSchedule(life: life, mood: mood, frameInterval: interval)
            let calmDates = Array(
                calm.entries(from: Date(timeIntervalSinceReferenceDate: start - 1), mode: .normal).prefix(5))
            #expect(calmDates.map(\.timeIntervalSinceReferenceDate) == [start - 1], "\(mood)")
            let schedule = BotinFaceSchedule(life: life, mood: mood, reactions: reactions, frameInterval: interval)
            let dates = Array(
                schedule.entries(from: Date(timeIntervalSinceReferenceDate: start - 1), mode: .normal).prefix(2_000)
            ).map(\.timeIntervalSinceReferenceDate)
            #expect(dates.count < 2_000, "\(mood): 做完以后还在给")
            #expect(dates.first == start - 1 && dates.dropFirst().first == start, "\(mood)")
            #expect(dates.last == ends[2], "\(mood): \(dates.last ?? 0)")
            #expect(dates.contains(ends[0]) && dates.contains(ends[1]) && dates.contains(reactions[2].start), "\(mood)")
            #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 }, "\(mood)")
            for (previous, date) in zip(dates.dropFirst(), dates.dropFirst(2)) where date - previous > interval + 1e-9 {
                // 两次反应之间的空档：从前一段的结尾直接跳到下一次的开头。
                #expect(previous == ends[1] && date == reactions[2].start, "\(mood): \(previous)→\(date)")
            }
            // 低频模式在反应里时给反应的结尾。
            let low = Array(
                schedule.entries(from: Date(timeIntervalSinceReferenceDate: start + 0.1), mode: .lowFrequency))
            #expect(low.map(\.timeIntervalSinceReferenceDate) == [ends[1]], "\(mood)")
        }
        // 在跑的：反应的窗口里每一帧都给。
        let active = BotinFaceSchedule(life: life, mood: .active, reactions: reactions, frameInterval: interval)
        let dates = Array(
            active.entries(from: Date(timeIntervalSinceReferenceDate: start - 1), mode: .normal).prefix(3_000)
        ).map(\.timeIntervalSinceReferenceDate)
        let insideReaction = zip(dates, dates.dropFirst()).filter { $0.0 >= start && $0.1 <= ends[1] }
        #expect(!insideReaction.isEmpty && insideReaction.allSatisfy { $0.1 - $0.0 <= interval + 1e-9 })
        #expect(ends.allSatisfy(dates.contains))
    }

    @Test("时间线的低频模式只给一个时刻：开始时刻，在窗口里时给窗口的结尾")
    func scheduleLowFrequency() {
        let life = BotinFaceLife(name: "周报助手")
        let schedule = BotinFaceSchedule(life: life, mood: .active, frameInterval: 1.0 / 60)
        // 找一个前面至少空出 0.01 秒的窗口。
        var window = life.nextActiveWindow(after: 815_000_000, mood: .active)
        while life.nextActiveWindow(after: window.lowerBound - 0.01, mood: .active).lowerBound != window.lowerBound {
            window = life.nextActiveWindow(after: window.upperBound, mood: .active)
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
        #expect(life.nextActiveWindow(after: resting, mood: .active).lowerBound > resting)
        let pose = life.pose(at: resting, mood: .active)
        #expect(pose.lid == 1 && pose.smile == 0 && pose.bodyOffsetY == 0 && pose.tilt == 0)
    }

    @Test("时间线：太远、不是有限数的时间给完开始时刻就结束，不原地打转；帧率按头像大小")
    func scheduleEdges() {
        for mood in BotinFaceMood.allCases {
            let schedule = BotinFaceSchedule(
                life: BotinFaceLife(name: "Pi"), mood: mood, reactions: [BotinFaceReaction(.tap, start: 1e13)],
                frameInterval: 1.0 / 60)
            for start in [1e13, -1e13, Double.infinity] {
                let dates = Array(
                    schedule.entries(from: Date(timeIntervalSinceReferenceDate: start), mode: .normal).prefix(5))
                #expect(dates.count == 1, "\(mood) \(start)")
            }
        }
        // 帧距不是正的有限数时按 1/60 秒。
        let life = BotinFaceLife(seed: 1)
        #expect(BotinFaceSchedule(life: life, mood: .active, frameInterval: 0).frameInterval == 1.0 / 60)
        #expect(BotinFaceSchedule(life: life, mood: .active, frameInterval: .nan).frameInterval == 1.0 / 60)
        #expect(BotinFaceSchedule.frameInterval(forSide: Metrics.Avatar.title) == 1.0 / 30)
        #expect(BotinFaceSchedule.frameInterval(forSide: Metrics.Avatar.list) == 1.0 / 30)
        #expect(BotinFaceSchedule.frameInterval(forSide: 60) == 1.0 / 60)
        #expect(BotinFaceSchedule.frameInterval(forSide: Metrics.Avatar.profile) == 1.0 / 60)
        // 减弱动态效果、截图开关：有一个关着就不动。
        #expect(BotinFace.motionAllowed(reduceMotion: false, botinFaceMotion: true))
        #expect(!BotinFace.motionAllowed(reduceMotion: true, botinFaceMotion: true))
        #expect(!BotinFace.motionAllowed(reduceMotion: false, botinFaceMotion: false))
    }

    @Test("头像的状态从角标推：在跑的运行是活的，等用户的睁大眼睛、连跳叫人，暂停、归档闭着眼，主 Botin 和别的不动")
    func moodFromBadge() {
        #expect(InstanceAvatar.mood(for: nil) == .resting)
        #expect(InstanceAvatar.mood(for: .primary) == .resting)
        #expect(
            InstanceAvatar.mood(for: .custom(StatusAppearance(tone: .waiting), accessibilityLabel: "等")) == .resting)
        #expect(InstanceAvatar.mood(for: .run(.running)) == .active)
        #expect(InstanceAvatar.mood(for: .run(.queued)) == .active)
        #expect(InstanceAvatar.mood(for: .run(.waitingChildren)) == .active)
        #expect(InstanceAvatar.mood(for: .run(.waitingApproval)) == .waiting)
        #expect(InstanceAvatar.mood(for: .run(.succeeded)) == .resting)
        #expect(InstanceAvatar.mood(for: .instance(.running)) == .resting)
        #expect(InstanceAvatar.mood(for: .instance(.paused)) == .sleeping)
        #expect(InstanceAvatar.mood(for: .instance(.archived)) == .still)
    }

    @Test("各种形状、颜色、尺寸、状态都画得出来（在跑的、不动的、在做反应的、关了动效的）")
    func renders() {
        let now = Date().timeIntervalSinceReferenceDate
        let reactions = [BotinFaceReaction(.tap, start: now), BotinFaceReaction(.happy, start: now + 0.3)]
        for shape in AvatarShape.allCases {
            renderInBothAppearances(
                BotinFace(
                    name: "周报助手", appearance: InstanceAppearance(shape: shape), size: Metrics.Avatar.list, mood: .active
                ))
            renderInBothAppearances(
                BotinFace(name: "翻译", appearance: InstanceAppearance(shape: shape, color: .grey), size: 32))
            renderInBothAppearances(
                BotinFace(
                    name: "盯盘", appearance: InstanceAppearance(shape: shape, color: .amber), size: Metrics.Avatar.list,
                    mood: .waiting))
        }
        for mood in BotinFaceMood.allCases {
            renderInBothAppearances(
                BotinFace(name: "盯盘", appearance: InstanceAppearance(shape: .star), size: 56, mood: mood))
            renderInBothAppearances(
                BotinFace(
                    name: "盯盘", appearance: InstanceAppearance(shape: .leaf), size: 80, mood: mood, reactions: reactions
                ))
            renderInBothAppearances(
                InstanceAvatar("盯盘", size: Metrics.Avatar.list, badge: .run(.running), mood: mood, reactions: reactions)
            )
        }
        for color in AvatarColor.allCases {
            renderInBothAppearances(
                BotinFace(
                    name: "Pi", appearance: InstanceAppearance(shape: .cloud, color: color), size: 120, mood: .active,
                    reactions: reactions
                )
                .environment(\.botinFaceMotion, false))
        }
        renderInBothAppearances(BotinFace(name: "", appearance: .default, size: Metrics.Avatar.title))
        // 新建表单的预览：节奏是给的，不按名字算；选头像的大预览。
        renderInBothAppearances(
            BotinFace(name: "写作助手", appearance: .default, size: 120, mood: .active, life: BotinFaceLife(seed: 7)))
        renderInBothAppearances(
            AvatarPickerPreview(name: "写作助手", appearance: InstanceAppearance(shape: .flower), size: 120))
    }

    // MARK: - 几何工具

    /// 模型做得出来的样子（`BotinFaceLife` 和反应，都夹过范围）：在跑、在等用户时两个 Botin 各 20 秒的每一帧（1/60 秒）；
    /// 每个小动作和两种反应从头到尾的每一帧，起点是在跑时看得到的各个方向（转眼的落点在 x² + (y / 0.8)² ≤ 1 里：边上
    /// 16 个方向和正前方）、眨眼眨到一半；两种反应和连跳也叠在不动的表情（等用户的睁大眼睛、睡着）上，连跳再叠在睁大眼睛
    /// 眨到一半上；还有几次反应叠在一起夹到头的样子（横竖都压到 0.88、笑眼、看到最远）。
    private static func reachablePoses() -> [Pose] {
        var poses = Set<Pose>()
        for name in ["周报助手", "翻译"] {
            let life = BotinFaceLife(name: name)
            for i in 0..<(20 * 60) {
                poses.insert(life.pose(at: 815_000_000 + Double(i) / 60, mood: .active))
                poses.insert(life.pose(at: 815_000_000 + Double(i) / 60, mood: .waiting))
            }
        }
        let directions: [Pose] =
            (0..<16).map { k in
                let angle = 2 * Double.pi * Double(k) / 16
                return Pose(gazeX: cos(angle), gazeY: 0.8 * sin(angle))
            } + [Pose(), Pose(lid: 0.5)]
        let waitingFace = BotinFaceLife.restPose(for: .waiting)
        let restingFaces = [waitingFace, BotinFaceLife.restPose(for: .sleeping)]
        var blinkingWide = waitingFace
        blinkingWide.lid = 0.5
        for gesture in BotinFaceGesture.allCases {
            let starts: [Pose] =
                switch gesture {
                case .tap, .happy: directions + restingFaces
                case .doubleHop: directions + restingFaces + [blinkingWide]
                case .hop, .tiltLeft, .tiltRight, .nod: directions
                }
            for start in starts {
                for u in stride(from: 0.0, through: gesture.duration, by: 1.0 / 60) {
                    poses.insert(start.adding(gesture, at: u))
                }
            }
        }
        for start in directions + restingFaces {
            for smile in [0.6, 1] {
                var pose = start
                pose.squashX = 0.88
                pose.squashY = 0.88
                pose.smile = smile
                poses.insert(pose.clamped())
            }
        }
        return Array(poses)
    }

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

    /// 一只眼睛折成的点（不变换）。
    private func eyeOutline(_ eye: BotinFaceLayout.Eye) -> [CGPoint] {
        var builder = AvatarPathBuilder(recordsOutline: true)
        BotinFaceShape.drawEye(eye, into: &builder)
        return builder.outline
    }

    private func every(_ stride: Int, of points: [CGPoint]) -> [CGPoint] {
        Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func close(
        _ eye: BotinFaceLayout.Eye, centerX: Double, centerY: Double, width: Double, height: Double
    ) -> Bool {
        abs(eye.centerX - centerX) < 1e-9 && abs(eye.centerY - centerY) < 1e-9 && abs(eye.width - width) < 1e-9
            && abs(eye.height - height) < 1e-9
    }
}

/// 一块区域里每隔 `step` 一个格点上到多边形的有符号距离（里面为正）。查一个点时取最近的格点再减去半条对角线：
/// 到边的距离挪 d 最多变 d，所以是这个点的距离的下界（不够时调用方再按多边形算准的）。
private struct DistanceGrid {
    let minX: Double
    let minY: Double
    let step: Double
    let columns: Int
    let rows: Int
    let values: [Double]

    init(_ polygon: Polygon, x: ClosedRange<Double>, y: ClosedRange<Double>, step: Double) {
        minX = x.lowerBound
        minY = y.lowerBound
        self.step = step
        columns = Int(((x.upperBound - x.lowerBound) / step).rounded(.up)) + 1
        rows = Int(((y.upperBound - y.lowerBound) / step).rounded(.up)) + 1
        var values: [Double] = []
        values.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: minX + Double(column) * step, y: minY + Double(row) * step)
                values.append(polygon.signedDistance(to: point))
            }
        }
        self.values = values
    }

    /// 点 `p` 的距离的下界；格子外面是 -∞（调用方按多边形算）。
    func lowerBound(at p: CGPoint) -> Double {
        let column = Int(((Double(p.x) - minX) / step).rounded())
        let row = Int(((Double(p.y) - minY) / step).rounded())
        guard (0..<columns).contains(column), (0..<rows).contains(row) else { return -.infinity }
        return values[row * columns + column] - step * 0.5 * 2.0.squareRoot()
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
