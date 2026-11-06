import Foundation

// Botin 头像上的脸在某一刻是什么样子（docs/ios-ui-redesign.md 4.4.4）：两只眼睛往哪儿看、睁开多少、是不是笑眼、睁多大，
// 身体往上挪多少、压扁拉长多少、歪多少。画法在 ThinktinUI 的 `BotinFace`，这里只管时间：一个 Botin 一个种子（名字的散列），
// 某一刻的样子只由种子、状态（`BotinFaceMood`，调用方给）、界面触发的反应（`BotinFaceReaction`，记的是开始的时刻）和时间
// 算出来，不存时钟、运行时不取随机数，每次算都是常数时间（按时间分槽，每个槽的随机数现算，不预先排一张会用完的表）。
//
// 平时（`idle`）眨眼、往四处看，偶尔做个小动作（跳一下、歪头、笑一下、点头，每 9 秒一个槽，一半多的槽里有一个）；
// 有运行在跑（`working`）时低头左右看着读、身体轻轻上下晃；等用户（`waiting`）时眼睛睁大往上看、每 3.4 秒连跳两下；
// 暂停了（`sleeping`）闭着眼慢慢呼吸；归档、删除了（`still`）闭着眼不动。点一下头像跳一下、笑一下，挑了形状、颜色笑一下。
//
// 除了一直在动的两种状态（读、呼吸），样子只在很短的“动的窗口”里变（眨一次 0.2 秒、转一次眼 0.16 秒、一个小动作 0.6 到
// 1.3 秒），窗口外面不变：界面只在窗口里逐帧重画，平时一帧都不画（`BotinFaceSchedule`）。所有的时长、幅度、节奏、概率都是
// 我们自己定的，不是照着 x.ai 头像的动作编排抄的（没有轨道环、彗星、爆开、感叹号、三个点、通知小圆点、漩涡这些）。

/// Botin 此刻的状态：决定脸平时在做什么。调用方按实例、运行的状态挑（`InstanceAvatar` 从角标推出来）；变了直接换，不做过渡。
public enum BotinFaceMood: Sendable, Hashable, CaseIterable {
    /// 平时：眨眼、往四处看，偶尔做个小动作（跳一下、歪头、笑一下、点头）。
    case idle
    /// 有运行在跑：眼睛往下、左右来回地看（像在读东西），身体轻轻上下晃，照常眨眼。
    case working
    /// 在等用户（审批、电脑、额度）：眼睛睁大、往上看，每 3.4 秒连着轻轻跳两下，照常眨眼。
    case waiting
    /// 暂停了：闭着眼慢慢呼吸（身体竖着一伸一缩）。
    case sleeping
    /// 归档、删除了：闭着眼，一动不动。
    case still

    /// 一直在动（读东西、呼吸）：没有不动的空档，时间表一直给帧。
    public var isContinuous: Bool {
        switch self {
        case .working, .sleeping: true
        case .idle, .waiting, .still: false
        }
    }
}

/// 一个小动作：平时偶尔做的（跳、歪头、笑、点头）、等用户时的连跳两下、界面触发的反应（点一下、挑了形状颜色）。
/// 每个都是从开始算起的时间的纯函数，开头和结尾都是不动的样子（`BotinFaceLife.Pose.adding(_:at:)`）。
public enum BotinFaceGesture: Sendable, Hashable, CaseIterable {
    /// 跳一下（0.62 秒）：先蹲（压扁），起跳时拉长，抛物线上去 0.075 再落下，落地压扁一下、弹回来；空中眯成笑眼（0.6）。
    case hop
    /// 往左歪头（1.3 秒）：0.25 秒歪过去 0.14 弧度，停 0.7 秒，0.35 秒回正；眼睛跟着往左看。
    case tiltLeft
    /// 往右歪头，同上。
    case tiltRight
    /// 笑一下（1.2 秒）：0.18 秒弯成笑眼，停 0.7 秒，0.32 秒变回来；开头身体轻轻往上弹一下（0.015）。
    case happy
    /// 点头（0.9 秒）：身体往下点两下（0.02），眼睛跟着往下看。
    case nod
    /// 点了一下头像（0.9 秒）：前 0.62 秒和 `hop` 一样跳一下，眼睛 0.15 秒弯成笑眼，到 0.9 秒变回来。
    case tap
    /// 等用户时连着轻轻跳两下（0.62 秒）：两次各 0.28 秒、高 0.035 的跳（`hop` 的身体曲线压短、压低），中间隔 0.06 秒。
    case doubleHop

    /// 做一遍多久（秒）。
    public var duration: TimeInterval {
        switch self {
        case .hop: BotinFaceLife.Timing.hopDuration
        case .tiltLeft, .tiltRight: 1.3
        case .happy: 1.2
        case .nod: 0.9
        case .tap: 0.9
        case .doubleHop: 2 * BotinFaceLife.Timing.waitingHopDuration + BotinFaceLife.Timing.waitingHopGap
        }
    }
}

/// 界面触发的一次反应（点了一下头像、挑了形状或颜色）：从 `start` 开始把一个小动作做一遍，和平时的动作叠在一起。
/// 记的是开始的时刻，样子照样是时间的纯函数（界面把最近的几次放在 `@State` 里，见 ThinktinUI 的 `BotinFace`）。
public struct BotinFaceReaction: Sendable, Hashable {
    public var gesture: BotinFaceGesture
    /// 开始的时刻（`Date.timeIntervalSinceReferenceDate`）。
    public var start: TimeInterval

    public init(_ gesture: BotinFaceGesture, start: TimeInterval) {
        self.gesture = gesture
        self.start = start
    }

    public init(_ gesture: BotinFaceGesture, at date: Date) {
        self.init(gesture, start: date.timeIntervalSinceReferenceDate)
    }

    /// 结束的时刻：这一刻起不再改样子。
    public var end: TimeInterval { start + gesture.duration }

    /// 这次反应在动的窗口；开始的时刻不是有限数、或者离 2001 年太远（`BotinFaceLife` 算不准）时没有。
    public var window: ClosedRange<TimeInterval>? {
        BotinFaceLife.supports(start) ? start...end : nil
    }

    /// 时刻 `t` 有没有反应正在做（开始的那一刻算，结束的那一刻不算）。
    public static func isActive(_ reactions: [BotinFaceReaction], at t: TimeInterval) -> Bool {
        reactions.contains { $0.window != nil && t >= $0.start && t < $0.end }
    }

    /// `t` 以后（不含 `t`）最早开始的反应的开始时刻；没有就是 nil。
    public static func nextStart(_ reactions: [BotinFaceReaction], after t: TimeInterval) -> TimeInterval? {
        reactions.filter { $0.window != nil && $0.start > t }.map(\.start).min()
    }
}

/// 一个 Botin 的脸怎么动：纯函数（种子 + 状态 + 反应 + 时间 → 样子），同一个名字在哪台设备上、哪次启动都一样。
public struct BotinFaceLife: Sendable, Hashable {
    /// 某一刻的样子。默认值都是不动（看正前方、睁着眼、身体不挪不变形、眼睛平常大小、不笑）。
    public struct Pose: Sendable, Hashable {
        /// 往左右看：-1 最左，0 正前方，1 最右。
        public var gazeX: Double
        /// 往上下看：-1 最上，0 正前方，1 最下。
        public var gazeY: Double
        /// 眼睛睁开多少：1 全睁开，0.1 闭上（留一条缝）。
        public var lid: Double
        /// 身体上下挪多少（单位正方形的边长算 1，负的往上）；眼睛跟着身体走。
        public var bodyOffsetY: Double
        /// 身体横向、竖向伸缩多少（以身体最下面的中点为准，脚底不动；1 不变）；眼睛跟着一起变。
        public var squashX: Double
        public var squashY: Double
        /// 身体绕中心 (0.5, 0.5) 歪多少（弧度，正的顺时针）；眼睛跟着一起歪。
        public var tilt: Double
        /// 眼睛放大多少（宽、高一起，以眼睛中心为准）：1 平常，大于 1 睁大。
        public var eyeScale: Double
        /// 笑眼：0 平常的椭圆，1 弯成“∩”（上半边不变，下半边往上收成一道弯），中间的按点插值。
        public var smile: Double

        public init(
            gazeX: Double = 0, gazeY: Double = 0, lid: Double = 1, bodyOffsetY: Double = 0, squashX: Double = 1,
            squashY: Double = 1, tilt: Double = 0, eyeScale: Double = 1, smile: Double = 0
        ) {
            self.gazeX = gazeX
            self.gazeY = gazeY
            self.lid = lid
            self.bodyOffsetY = bodyOffsetY
            self.squashX = squashX
            self.squashY = squashY
            self.tilt = tilt
            self.eyeScale = eyeScale
            self.smile = smile
        }

        /// 每一项夹回能画的范围（`Limits`），NaN 换成不动时的值：一个坏值不会把眼睛画到身体外面、把身体挪出头像。
        public func clamped() -> Pose {
            Pose(
                gazeX: Self.clamp(gazeX, -1...1, otherwise: 0), gazeY: Self.clamp(gazeY, -1...1, otherwise: 0),
                lid: Self.clamp(lid, Limits.lid, otherwise: 1),
                bodyOffsetY: Self.clamp(bodyOffsetY, -Limits.bodyOffset...Limits.bodyOffset, otherwise: 0),
                squashX: Self.clamp(squashX, Limits.squash, otherwise: 1),
                squashY: Self.clamp(squashY, Limits.squash, otherwise: 1),
                tilt: Self.clamp(tilt, -Limits.tilt...Limits.tilt, otherwise: 0),
                eyeScale: Self.clamp(eyeScale, Limits.eyeScale, otherwise: 1),
                smile: Self.clamp(smile, 0...1, otherwise: 0))
        }

        /// 叠上一个小动作做到第 `u` 秒时的样子，再夹回能画的范围；`u` 不在 [0, 时长) 里时只夹范围。
        public func adding(_ gesture: BotinFaceGesture, at u: TimeInterval) -> Pose {
            var pose = self
            pose.add(gesture, at: u)
            return pose.clamped()
        }

        private static func clamp(_ value: Double, _ range: ClosedRange<Double>, otherwise fallback: Double) -> Double {
            value.isNaN ? fallback : min(range.upperBound, max(range.lowerBound, value))
        }
    }

    /// 各项能到的范围（`Pose.clamped()` 按它夹，画的时候也按它夹）。身体往上下挪最多 0.08、压扁拉长在 0.88 到 1.10 之间：
    /// 身体基本还在头像的方框里。
    public enum Limits {
        public static let lid: ClosedRange<Double> = 0.1...1
        public static let bodyOffset = 0.08
        public static let squash: ClosedRange<Double> = 0.88...1.10
        public static let tilt = 0.15
        public static let eyeScale: ClosedRange<Double> = 0.8...1.12
    }

    /// 不动的样子：看正前方、眼睛睁着（关了动效、截图、选形状的格子里用）。
    public static let restPose = Pose()

    /// 这种状态不动时的表情（系统打开“减弱动态效果”、截图时用；小头像睡着时也是这样）：等用户时眼睛睁大往上看，
    /// 睡着、归档时闭着眼（比平时宽一点），别的是不动的样子。
    public static func restPose(for mood: BotinFaceMood) -> Pose {
        switch mood {
        case .idle, .working: restPose
        case .waiting: Pose(gazeY: Timing.waitingGazeY, eyeScale: Timing.waitingEyeScale)
        case .sleeping, .still: Pose(lid: Timing.sleepingLid, eyeScale: Timing.sleepingEyeScale)
        }
    }

    /// 种子：决定这个 Botin 什么时候眨眼、往哪儿看、做什么小动作。
    public let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
    }

    /// 按名字取种子：去掉首尾空白、转小写后的 FNV-1a 散列（64 位，跨进程、跨设备稳定；不用 `Hasher`，它每次启动的
    /// 种子不一样）。同一个 Botin 在列表和标题上同时出现时一起眨眼、一起动。
    public init(name: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        self.init(seed: hash)
    }

    /// 时刻 `t`（`Date.timeIntervalSinceReferenceDate`）、状态 `mood` 下的样子，叠上正在做的反应。`t` 不是有限数、或者离
    /// 2001 年太远（超过 `Timing.supportedRange`）时返回这种状态不动时的表情（`restPose(for:)`）。
    public func pose(
        at t: TimeInterval, mood: BotinFaceMood = .idle, reactions: [BotinFaceReaction] = []
    ) -> Pose {
        guard Self.supports(t) else { return Self.restPose(for: mood) }
        var pose: Pose
        switch mood {
        case .idle:
            let gaze = gaze(at: t)
            pose = Pose(gazeX: gaze.x, gazeY: gaze.y, lid: lid(at: t))
            if let gesture = idleGesture(slot: Self.slot(of: t, length: Timing.gestureSlot)),
                t >= gesture.start, t < gesture.start + gesture.kind.duration
            {
                pose.add(gesture.kind, at: t - gesture.start)
            }
        case .working:
            pose = Pose(
                gazeX: Timing.readingReach * sin(2 * Double.pi * Self.phase(of: t, period: Timing.readingPeriod) + readingPhase),
                gazeY: Timing.workingGazeY, lid: lid(at: t),
                bodyOffsetY: -Timing.bobHeight * Self.wave(Self.phase(of: t, period: Timing.bobPeriod)))
        case .waiting:
            pose = Self.restPose(for: .waiting)
            pose.lid = lid(at: t)
            let start = waitingHopStart(slot: Self.slot(of: t, length: Timing.waitingSlot))
            if t >= start, t < start + BotinFaceGesture.doubleHop.duration {
                pose.add(.doubleHop, at: t - start)
            }
        case .sleeping:
            pose = Self.restPose(for: .sleeping)
            let breath = Timing.breathDepth * Self.wave(Self.phase(of: t, period: Timing.breathPeriod))
            pose.squashY = 1 + breath
            pose.squashX = 1 - Timing.breathWidthRatio * breath
        case .still:
            pose = Self.restPose(for: .still)
        }
        for reaction in reactions where reaction.window != nil && t >= reaction.start && t < reaction.end {
            pose.add(reaction.gesture, at: t - reaction.start)
        }
        return pose.clamped()
    }

    /// 时刻 `t` 以后（含正在进行的）最早的一个动的窗口：上界大于 `t` 的窗口里开始得最早的那个（`t` 在窗口里就是这个
    /// 窗口）。窗口外面样子不变，界面只在窗口里逐帧重画。一直在动的状态（`BotinFaceMood.isContinuous`）没有空档：
    /// 时间切成一段段 4 秒的窗口，`t` 总在一个窗口里。往后再也不会动了（`still`，没有还没做完的反应）时是 +∞…+∞。
    /// `t` 不是有限数、或者离 2001 年太远时返回从 `t` 开始的空窗口（`t` 是 NaN 时是 +∞）：调用方看到上界不大于 `t`
    /// 就别再等下一个窗口了。
    public func nextActiveWindow(
        after t: TimeInterval, mood: BotinFaceMood = .idle, reactions: [BotinFaceReaction] = []
    ) -> ClosedRange<TimeInterval> {
        guard Self.supports(t) else { return t.isNaN ? .infinity ... .infinity : t...t }
        var best: ClosedRange<TimeInterval>?
        func consider(_ window: ClosedRange<TimeInterval>?) {
            guard let window, window.upperBound > t else { return }
            if let current = best, current.lowerBound <= window.lowerBound { return }
            best = window
        }
        switch mood {
        case .idle:
            consider(nextBlinkWindow(after: t))
            consider(nextGlanceWindow(after: t))
            consider(nextGestureWindow(after: t))
        case .working:
            consider(Self.continuousWindow(containing: t))
            consider(nextBlinkWindow(after: t))
        case .waiting:
            consider(nextBlinkWindow(after: t))
            consider(nextWaitingHopWindow(after: t))
        case .sleeping:
            consider(Self.continuousWindow(containing: t))
        case .still:
            break
        }
        for reaction in reactions {
            consider(reaction.window)
        }
        return best ?? .infinity ... .infinity
    }

    // MARK: - 时间参数（我们自己定的）

    enum Timing {
        /// 眨眼的槽长：每个槽眨一次（偶尔连眨两次）。
        static let blinkSlot: TimeInterval = 4.2
        /// 槽里眨眼的时刻：槽中间，前后随机错开 `blinkJitter` 的一半。
        static let blinkCenter: TimeInterval = 2.1
        static let blinkJitter: TimeInterval = 3.2
        /// 闭眼（先慢后快）、闭着、睁眼（先快后慢）各多久；加起来是一次眨眼的窗口。
        static let blinkClose: TimeInterval = 0.07
        static let blinkHold: TimeInterval = 0.03
        static let blinkOpen: TimeInterval = 0.10
        static let blinkDuration: TimeInterval = blinkClose + blinkHold + blinkOpen
        /// 闭上时眼睛还剩多高（留一条缝，不整个消失）。
        static let closedLid = 0.1
        /// 连眨两次的概率，第二次在第一次开始后多久开始。
        static let doubleBlinkChance = 0.12
        static let doubleBlinkGap: TimeInterval = 0.28

        /// 转眼的槽长：每个槽转一次，开始的时刻在槽头往后随机 0 到 `glanceJitter`。
        static let glanceSlot: TimeInterval = 2.8
        static let glanceJitter: TimeInterval = 0.9
        /// 眼睛转过去用多久（先快后慢），之后停在那儿等下一次。
        static let glanceDuration: TimeInterval = 0.16
        /// 看回正前方的概率。
        static let lookAheadChance = 0.4
        /// 不看正前方时看多远：0.55 到 1（满幅）；上下比左右少一点。
        static let minimumReach = 0.55
        static let reachSpread = 0.45
        static let verticalReach = 0.8

        /// 平时的小动作：9 秒一个槽，55% 的槽里有一个，开始的时刻在槽头后 1.5 到 6.5 秒（最长的歪头 1.3 秒，最晚在槽头后
        /// 7.8 秒做完，和下一个槽的不会碰上）。做哪个：跳 30%、歪头 25%、笑 25%、点头 20%。
        static let gestureSlot: TimeInterval = 9
        static let gestureChance = 0.55
        static let gestureEarliest: TimeInterval = 1.5
        static let gestureSpread: TimeInterval = 5
        static let hopShare = 0.30
        static let tiltShare = 0.25
        static let happyShare = 0.25

        /// 跳一下：时长、跳多高。
        static let hopDuration: TimeInterval = 0.62
        static let hopHeight = 0.075
        /// 起跳、落地的时刻（中间是抛物线）。
        static let hopTakeOff: TimeInterval = 0.10
        static let hopLanding: TimeInterval = 0.42
        /// 跳的时候空中的笑眼。
        static let hopSmile = 0.6
        /// 歪头歪多少（弧度）、眼睛跟着往那边看多远。
        static let tiltAngle = 0.14
        static let tiltGaze = 0.5
        /// 笑一下时身体往上弹多高、在 0.1 到 0.3 秒之间。
        static let happyBounce = 0.015
        static let happyBounceStart: TimeInterval = 0.1
        static let happyBounceLength: TimeInterval = 0.2
        /// 点头：往下点多少、眼睛往下看多少，两下的中心、每下多长。
        static let nodDepth = 0.02
        static let nodGaze = 0.4
        static let nodCenters: [TimeInterval] = [0.18, 0.58]
        static let nodLength: TimeInterval = 0.3

        /// 在读东西：眼睛往下看多少、左右看多远、来回一趟多久；身体上下晃多高、一趟多久。
        static let workingGazeY = 0.55
        static let readingReach = 0.6
        static let readingPeriod: TimeInterval = 2.6
        static let bobHeight = 0.012
        static let bobPeriod: TimeInterval = 1.15

        /// 等用户：眼睛睁多大、往上看多少；每 3.4 秒一个槽，槽头后 0.4 秒连跳两下（每下 0.28 秒、高 0.035，隔 0.06 秒）。
        static let waitingEyeScale = 1.12
        static let waitingGazeY = -0.35
        static let waitingSlot: TimeInterval = 3.4
        static let waitingHopLead: TimeInterval = 0.4
        static let waitingHopDuration: TimeInterval = 0.28
        static let waitingHopGap: TimeInterval = 0.06
        static let waitingHopHeight = 0.035

        /// 睡着、归档：闭着的眼睛留多少缝、比平时宽多少；呼吸：竖着最多伸长多少、一呼一吸多久，横着跟着收多少（伸长的 0.4 倍）。
        static let sleepingLid = 0.12
        static let sleepingEyeScale = 1.12
        static let breathDepth = 0.025
        static let breathPeriod: TimeInterval = 3.6
        static let breathWidthRatio = 0.4

        /// 一直在动的状态把时间切成多长的窗口（2 的幂，切点算得准）。
        static let continuousChunk: TimeInterval = 4

        /// 算得准的时间范围（秒，离 2001 年）：再远浮点数的精度不够分槽，按不动处理。`Date.distantFuture` 约 6.3e10。
        static let supportedRange: TimeInterval = 1e12
    }

    /// 每个槽里用的几路随机数（同一个槽、不同用途各取一路）。
    enum Stream: UInt64 {
        case blinkOffset = 1
        case doubleBlink = 2
        case glanceOffset = 3
        case lookAhead = 4
        case glanceAngle = 5
        case glanceReach = 6
        case gesture = 7
        case gestureOffset = 8
        case gestureKind = 9
        case tiltSide = 10
        /// 读东西时眼睛来回的相位（只用第 0 个槽）。
        case readingPhase = 11
    }

    // MARK: - 眨眼

    /// 槽 `slot` 里眨眼开始的时刻：第一次一定有，第二次（连眨）可能有。都在槽里：最早槽头后 0.5 秒，最晚的窗口
    /// 在槽尾前 0.02 秒结束。
    func blinkStarts(slot: Int64) -> (first: TimeInterval, second: TimeInterval?) {
        let first =
            Double(slot) * Timing.blinkSlot + Timing.blinkCenter
            + (random(slot: slot, stream: .blinkOffset) - 0.5) * Timing.blinkJitter
        let second =
            random(slot: slot, stream: .doubleBlink) < Timing.doubleBlinkChance ? first + Timing.doubleBlinkGap : nil
        return (first, second)
    }

    /// 眼睛睁开多少：前后三个槽里的眨眼取最小（同一时刻最多一次眨眼在进行）。
    func lid(at t: TimeInterval) -> Double {
        let slot = Self.slot(of: t, length: Timing.blinkSlot)
        var lid = 1.0
        for neighbour in (slot - 1)...(slot + 1) {
            let starts = blinkStarts(slot: neighbour)
            lid = min(lid, Self.blinkLid(at: t, start: starts.first))
            if let second = starts.second {
                lid = min(lid, Self.blinkLid(at: t, start: second))
            }
        }
        return lid
    }

    /// `start` 开始的一次眨眼在 `t` 时眼睛睁开多少：闭眼先慢后快（二次缓入）、闭着停一下、睁眼先快后慢（二次缓出）。
    /// 窗口两头和 `nextActiveWindow` 报的一样按 `start + blinkDuration` 比（不按 `t - start` 比：时间的量级在 1e8 秒，
    /// 两种算法差一个浮点数的最小单位，窗口刚结束的那一刻会差一点没睁全）。小动作、反应也都这样比。
    static func blinkLid(at t: TimeInterval, start: TimeInterval) -> Double {
        guard t > start, t < start + Timing.blinkDuration else { return 1 }
        let elapsed = t - start
        let open = 1 - Timing.closedLid
        if elapsed < Timing.blinkClose {
            let p = elapsed / Timing.blinkClose
            return 1 - open * p * p
        }
        if elapsed < Timing.blinkClose + Timing.blinkHold {
            return Timing.closedLid
        }
        let p = min(1, (elapsed - Timing.blinkClose - Timing.blinkHold) / Timing.blinkOpen)
        return Timing.closedLid + open * (1 - (1 - p) * (1 - p))
    }

    func nextBlinkWindow(after t: TimeInterval) -> ClosedRange<TimeInterval> {
        let slot = Self.slot(of: t, length: Timing.blinkSlot)
        // 这个槽里还没结束的；都结束了就是下一个槽的第一次（它在槽头 0.5 秒以后，一定在 t 以后）。
        let current = blinkStarts(slot: slot)
        for start in [current.first, current.second].compactMap({ $0 }) where start + Timing.blinkDuration > t {
            return start...(start + Timing.blinkDuration)
        }
        let next = blinkStarts(slot: slot + 1).first
        return next...(next + Timing.blinkDuration)
    }

    // MARK: - 看向

    /// 槽 `slot` 里眼睛开始转的时刻。
    func glanceStart(slot: Int64) -> TimeInterval {
        Double(slot) * Timing.glanceSlot + random(slot: slot, stream: .glanceOffset) * Timing.glanceJitter
    }

    /// 槽 `slot` 里眼睛转到哪儿：40% 看回正前方，其余随便一个方向、0.55 到满幅，上下的幅度小一点。
    func glanceTarget(slot: Int64) -> (x: Double, y: Double) {
        guard random(slot: slot, stream: .lookAhead) >= Timing.lookAheadChance else { return (0, 0) }
        let angle = 2 * Double.pi * random(slot: slot, stream: .glanceAngle)
        let reach = Timing.minimumReach + Timing.reachSpread * random(slot: slot, stream: .glanceReach)
        return (Self.clampUnit(reach * cos(angle)), Self.clampUnit(Timing.verticalReach * reach * sin(angle)))
    }

    /// 看向：最近一次开始转（开始时刻不晚于 `t` 的最后一个槽）从上一次的落点转到这次的落点（三次缓出），转完停住。
    func gaze(at t: TimeInterval) -> (x: Double, y: Double) {
        let slot = Self.slot(of: t, length: Timing.glanceSlot)
        // 这个槽的还没开始就是上一个槽的（上一个槽的开始时刻最晚在它的槽头后 0.9 秒，早于这个槽头）。
        let latest = glanceStart(slot: slot) <= t ? slot : slot - 1
        let start = glanceStart(slot: latest)
        let target = glanceTarget(slot: latest)
        // 和 `blinkLid` 一样按窗口的上界比，窗口一结束就正好停在落点上。
        guard t < start + Timing.glanceDuration else { return target }
        let from = glanceTarget(slot: latest - 1)
        let p = min(1, max(0, (t - start) / Timing.glanceDuration))
        let eased = 1 - (1 - p) * (1 - p) * (1 - p)
        return (from.x + (target.x - from.x) * eased, from.y + (target.y - from.y) * eased)
    }

    func nextGlanceWindow(after t: TimeInterval) -> ClosedRange<TimeInterval> {
        let slot = Self.slot(of: t, length: Timing.glanceSlot)
        let start = glanceStart(slot: slot)
        if start + Timing.glanceDuration > t {
            return start...(start + Timing.glanceDuration)
        }
        let next = glanceStart(slot: slot + 1)
        return next...(next + Timing.glanceDuration)
    }

    // MARK: - 平时的小动作

    /// 槽 `slot` 里的小动作（没有就是 nil）：开始的时刻、做哪个。
    func idleGesture(slot: Int64) -> (start: TimeInterval, kind: BotinFaceGesture)? {
        guard random(slot: slot, stream: .gesture) < Timing.gestureChance else { return nil }
        let start =
            Double(slot) * Timing.gestureSlot + Timing.gestureEarliest
            + random(slot: slot, stream: .gestureOffset) * Timing.gestureSpread
        let pick = random(slot: slot, stream: .gestureKind)
        let kind: BotinFaceGesture
        if pick < Timing.hopShare {
            kind = .hop
        } else if pick < Timing.hopShare + Timing.tiltShare {
            kind = random(slot: slot, stream: .tiltSide) < 0.5 ? .tiltLeft : .tiltRight
        } else if pick < Timing.hopShare + Timing.tiltShare + Timing.happyShare {
            kind = .happy
        } else {
            kind = .nod
        }
        return (start, kind)
    }

    /// 这个槽和后面三个槽里第一个还没做完的小动作的窗口；都没有时是 nil（这时 9 秒以内一定有眨眼、转眼的窗口，
    /// `nextActiveWindow` 用不着更远的）。小动作不跨槽，前一个槽的在这个槽头以前就做完了。
    func nextGestureWindow(after t: TimeInterval) -> ClosedRange<TimeInterval>? {
        let slot = Self.slot(of: t, length: Timing.gestureSlot)
        for candidate in slot...(slot + 3) {
            guard let gesture = idleGesture(slot: candidate) else { continue }
            let end = gesture.start + gesture.kind.duration
            if end > t { return gesture.start...end }
        }
        return nil
    }

    // MARK: - 等用户、一直在动

    /// 等用户时槽 `slot` 里连跳两下开始的时刻。
    func waitingHopStart(slot: Int64) -> TimeInterval {
        Double(slot) * Timing.waitingSlot + Timing.waitingHopLead
    }

    func nextWaitingHopWindow(after t: TimeInterval) -> ClosedRange<TimeInterval> {
        let slot = Self.slot(of: t, length: Timing.waitingSlot)
        let duration = BotinFaceGesture.doubleHop.duration
        let current = waitingHopStart(slot: slot)
        if current + duration > t { return current...(current + duration) }
        let next = waitingHopStart(slot: slot + 1)
        return next...(next + duration)
    }

    /// 一直在动的状态里 `t` 所在的那段窗口（4 秒一段，切点在 4 的整数倍上）。
    static func continuousWindow(containing t: TimeInterval) -> ClosedRange<TimeInterval> {
        let start = (t / Timing.continuousChunk).rounded(.down) * Timing.continuousChunk
        return start...(start + Timing.continuousChunk)
    }

    /// 读东西时眼睛来回的相位（弧度，每个 Botin 不一样）。
    var readingPhase: Double {
        2 * Double.pi * random(slot: 0, stream: .readingPhase)
    }

    /// `t` 在周期 `period` 里走到哪儿了：[0, 1)（负的时间也一样，先取余数再除，时间的量级在 1e8 秒时也算得准）。
    static func phase(of t: TimeInterval, period: TimeInterval) -> Double {
        let remainder = t.truncatingRemainder(dividingBy: period)
        return (remainder < 0 ? remainder + period : remainder) / period
    }

    /// 0 到 1 再回到 0 的平滑起伏（余弦）：相位 0 时 0，0.5 时 1。
    static func wave(_ phase: Double) -> Double {
        0.5 - 0.5 * cos(2 * Double.pi * phase)
    }

    // MARK: - 散列、分槽

    /// 槽 `slot`、第 `stream` 路的随机数，[0, 1)：种子、槽号、路号依次用 SplitMix64 的混合函数搅在一起。
    func random(slot: Int64, stream: Stream) -> Double {
        let mixed = Self.mix(Self.mix(Self.mix(seed) ^ UInt64(bitPattern: slot)) ^ stream.rawValue)
        return Double(mixed >> 11) / 9_007_199_254_740_992  // 2^53：取高 53 位，正好是 Double 的精度。
    }

    /// SplitMix64 的一步：加黄金比例常数，再两次异或移位乘。
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// `t` 落在第几个槽（槽 n 是 [n × length, (n + 1) × length)）。调用前已经确认 `t` 在 `supportedRange` 里。
    static func slot(of t: TimeInterval, length: TimeInterval) -> Int64 {
        Int64((t / length).rounded(.down))
    }

    static func supports(_ t: TimeInterval) -> Bool {
        t.isFinite && abs(t) <= Timing.supportedRange
    }

    private static func clampUnit(_ value: Double) -> Double {
        min(1, max(-1, value))
    }
}

// MARK: - 小动作的曲线

extension BotinFaceLife.Pose {
    /// 叠上小动作 `gesture` 做到第 `u` 秒时的改动（不夹范围，`pose(at:)` 最后统一夹）：身体的挪动、歪的角度相加，
    /// 伸缩相乘，笑眼取大的，看向往动作要看的方向拉。`u` 不在 [0, 时长) 里时不变。
    mutating func add(_ gesture: BotinFaceGesture, at u: TimeInterval) {
        typealias Timing = BotinFaceLife.Timing
        guard u >= 0, u < gesture.duration else { return }
        switch gesture {
        case .hop:
            applyBody(Self.hopBody(at: u))
            smile = max(smile, Self.hopSmile.value(at: u))
        case .tap:
            applyBody(Self.hopBody(at: u))
            smile = max(smile, Self.tapSmile.value(at: u))
        case .tiltLeft, .tiltRight:
            let side: Double = gesture == .tiltRight ? 1 : -1
            let amount = Self.tiltCurve.value(at: u)
            tilt += side * Timing.tiltAngle * amount
            gazeX += (side * Timing.tiltGaze - gazeX) * amount
        case .happy:
            smile = max(smile, Self.happySmile.value(at: u))
            bodyOffsetY -= Timing.happyBounce * Self.bump((u - Timing.happyBounceStart) / Timing.happyBounceLength)
        case .nod:
            let dip = Timing.nodCenters.reduce(0) { sum, center in
                sum + Self.bump((u - center) / Timing.nodLength + 0.5)
            }
            bodyOffsetY += Timing.nodDepth * dip
            gazeY += Timing.nodGaze * dip
        case .doubleHop:
            // 两下各用 `hop` 的身体曲线（时间压到 0.28 秒，高度、伸缩压到 0.035 / 0.075 倍）。
            let scale = Timing.hopDuration / Timing.waitingHopDuration
            let amplitude = Timing.waitingHopHeight / Timing.hopHeight
            for start in [0, Timing.waitingHopDuration + Timing.waitingHopGap] where u >= start {
                let local = u - start
                guard local < Timing.waitingHopDuration else { continue }
                let body = Self.hopBody(at: local * scale)
                applyBody(
                    (
                        offset: body.offset * amplitude, squashX: 1 + (body.squashX - 1) * amplitude,
                        squashY: 1 + (body.squashY - 1) * amplitude
                    ))
            }
        }
    }

    private mutating func applyBody(_ body: (offset: Double, squashX: Double, squashY: Double)) {
        bodyOffsetY += body.offset
        squashX *= body.squashX
        squashY *= body.squashY
    }

    /// 跳一下的身体（`u` 秒，0 到 0.62）：0–0.10 蹲下（竖着压到 0.90、横着撑到 1.08，先快后慢），0.10–0.14 一下子拉长
    /// （1.06 / 0.96），到 0.26（最高点）缓回 1；0.10–0.42 抛物线上去 0.075 再落下；0.42–0.47 落地压扁（0.94 / 1.05），
    /// 停到 0.50，0.50–0.62 弹回 1（先快后慢）。都是连续的。
    static func hopBody(at u: TimeInterval) -> (offset: Double, squashX: Double, squashY: Double) {
        typealias Timing = BotinFaceLife.Timing
        var offset = 0.0
        if u > Timing.hopTakeOff, u < Timing.hopLanding {
            let p = (u - Timing.hopTakeOff) / (Timing.hopLanding - Timing.hopTakeOff)
            offset = -Timing.hopHeight * 4 * p * (1 - p)
        }
        return (offset, hopSquashX.value(at: u), hopSquashY.value(at: u))
    }

    static let hopSquashY = Keyframes([
        (0, 1, .linear), (0.10, 0.90, .easeOut), (0.14, 1.06, .easeInOut), (0.26, 1, .easeInOut), (0.42, 1, .linear),
        (0.47, 0.94, .easeOut), (0.50, 0.94, .linear), (0.62, 1, .easeOut),
    ])
    static let hopSquashX = Keyframes([
        (0, 1, .linear), (0.10, 1.08, .easeOut), (0.14, 0.96, .easeInOut), (0.26, 1, .easeInOut), (0.42, 1, .linear),
        (0.47, 1.05, .easeOut), (0.50, 1.05, .linear), (0.62, 1, .easeOut),
    ])
    /// 跳的时候：蹲下时眯起来，空中 0.6，落地以后变回来。
    static let hopSmile = Keyframes([
        (0, 0, .linear), (0.10, 0.6, .easeOut), (0.42, 0.6, .linear), (0.62, 0, .easeInOut),
    ])
    /// 点一下：0.15 秒弯成笑眼，停到 0.5 秒，0.9 秒变回来。
    static let tapSmile = Keyframes([
        (0, 0, .linear), (0.15, 1, .easeOut), (0.5, 1, .linear), (0.9, 0, .easeInOut),
    ])
    /// 歪头歪到几成：0.25 秒歪过去（先快后慢），停 0.7 秒，0.35 秒回正。
    static let tiltCurve = Keyframes([
        (0, 0, .linear), (0.25, 1, .easeOut), (0.95, 1, .linear), (1.3, 0, .easeInOut),
    ])
    /// 笑一下：0.18 秒弯成笑眼，停 0.7 秒，0.32 秒变回来。
    static let happySmile = Keyframes([
        (0, 0, .linear), (0.18, 1, .easeOut), (0.88, 1, .linear), (1.2, 0, .easeInOut),
    ])

    /// 0 到 1 之间的一个起伏（正弦的平方，两头平着进出）：`p` 在 [0, 1] 外是 0，0.5 时是 1。
    static func bump(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return 0 }
        let s = sin(Double.pi * p)
        return s * s
    }
}

/// 一条关键帧曲线：从第一帧的值开始，每一帧在它的时刻到达它的值，路上按它的缓动走；最后一帧以后停在最后一帧的值上。
struct Keyframes: Sendable {
    enum Ease: Sendable {
        case linear
        /// 先快后慢（二次）。
        case easeOut
        /// 慢进慢出（smoothstep）。
        case easeInOut

        func apply(_ p: Double) -> Double {
            switch self {
            case .linear: p
            case .easeOut: 1 - (1 - p) * (1 - p)
            case .easeInOut: p * p * (3 - 2 * p)
            }
        }
    }

    struct Key: Sendable {
        var time: TimeInterval
        var value: Double
        /// 从上一帧走到这一帧用的缓动（第一帧的不用）。
        var ease: Ease
    }

    let keys: [Key]

    init(_ keys: [(TimeInterval, Double, Ease)]) {
        self.keys = keys.map { Key(time: $0.0, value: $0.1, ease: $0.2) }
    }

    func value(at u: TimeInterval) -> Double {
        guard let first = keys.first else { return 0 }
        guard u > first.time else { return first.value }
        for (from, to) in zip(keys, keys.dropFirst()) where u < to.time {
            let p = (u - from.time) / (to.time - from.time)
            return from.value + (to.value - from.value) * to.ease.apply(p)
        }
        return keys[keys.count - 1].value
    }
}
