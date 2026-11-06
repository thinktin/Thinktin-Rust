import Foundation

// Botin 头像上的脸在某一刻是什么样子（docs/ios-ui-redesign.md 4.4.4）：两只眼睛往哪儿看、睁开多少、是不是笑眼、睁多大，
// 身体往上挪多少、压扁拉长多少、歪多少。画法在 ThinktinUI 的 `BotinFace`，这里只管时间：一个 Botin 一个种子（名字的散列），
// 某一刻的样子只由种子、状态（`BotinFaceMood`，调用方给）、界面触发的反应（`BotinFaceReaction`，记的是开始的时刻）和时间
// 算出来，不存时钟、运行时不取随机数，每次算都是常数时间（按时间分槽，每个槽的随机数现算，不预先排一张会用完的表）。
//
// 用户 2026-11-06 定的四条：“没有运行中的会话就不要眨眼或者有动作了”“在会话列表里运行中也要随机展示动作”“选头像的时候，
// 选中时候要有动作展示”“等你审批的 Botin 要动”。所以有任务在跑的 Botin（`active`）眨眼、往四处看，隔一阵随机做个小动作
// （跳一下、歪头、笑一下、点头）；在等用户的（`waiting`：审批、电脑、额度）眼睛睁大往上看着用户、照样眨眼，每 3.4 秒连着
// 小跳两下叫人（`BotinFaceGesture.doubleHop`），两次之间不转眼、不做别的小动作；别的状态都是一张不动的脸（暂停、归档时
// 闭着眼）。用户点了、挑了东西时的反应（点一下跳一下、挑了形状颜色笑一下）不管什么状态都做。
//
// 样子只在很短的“动的窗口”里变（眨一次 0.2 秒、转一次眼 0.16 秒、一个小动作 0.62 到 1.3 秒），窗口外面不变：界面只在窗口里
// 逐帧重画，平时一帧都不画（`BotinFaceSchedule`）。所有的时长、幅度、节奏、概率都是我们自己定的，不是照着 x.ai 头像的动作
// 编排抄的（没有轨道环、彗星、爆开、感叹号、三个点、通知小圆点、漩涡这些）。

/// Botin 此刻的状态：决定脸是不是自己在动、动的时候做什么、不动时是什么表情。调用方按运行、实例的状态挑（`InstanceAvatar`
/// 从角标推出来，也可以直接给）。变成 `active`、`waiting` 时从这种状态不动的样子开始动（界面记下变的时刻，
/// `BotinFaceLife.pose(at:mood:since:reactions:)`：第一帧和不动时一样，不会一下子跳到半路的小动作、转过去的眼睛上）；换成
/// 别的状态时直接换成那种状态的样子，正在做的随机小动作、转过去的眼睛、连跳都不做完（用户定的“没在跑就不动”）。用户点出来
/// 的反应照样做完。
public enum BotinFaceMood: Sendable, Hashable, CaseIterable {
    /// 平时（没有任务在跑）：看正前方、睁着眼，一动不动。
    case resting
    /// 有任务在跑（排队、启动、运行、等子任务、重试等待），也用在选头像时选中的那一格和上面的大预览：眨眼、往四处看，
    /// 隔一阵随机做个小动作（跳一下、歪头、笑一下、点头）。
    case active
    /// 在等用户（审批、电脑、额度）：眼睛睁大（1.12 倍）、往上看着用户（-0.35），照样眨眼；每 3.4 秒连着小跳两下叫人
    /// （`BotinFaceGesture.doubleHop`，所有在等的 Botin 一起跳），两次之间一动不动（不转眼、不做随机的小动作）。用户
    /// 2026-11-06 定的“等你审批的 Botin 要动”。
    case waiting
    /// 暂停了：闭着眼（比平时宽一点），不动。
    case sleeping
    /// 归档、删除了：闭着眼，不动。
    case still

    /// 会自己动（有时间线）：`active`（眨眼、转眼、随机的小动作）和 `waiting`（眨眼、连跳两下）。别的状态只在做反应的
    /// 那一小会儿动。
    public var isAlive: Bool { self == .active || self == .waiting }

    /// 一次运行的状态对应的：在跑（排队、启动、运行、等子任务、重试等待）是 `active`，等审批、电脑、额度是 `waiting`，
    /// 结束了（成功、失败、取消）和不认识的是 `resting`。
    public init(run state: RunState) {
        switch state {
        case .queued, .starting, .running, .waitingChildren, .backoff: self = .active
        case .waitingApproval, .waitingDevice, .waitingQuota: self = .waiting
        case .succeeded, .failed, .cancelled, .unknown: self = .resting
        }
    }

    /// 实例的状态对应的（没有任务在跑的时候）：暂停了是 `sleeping`，归档、删除了是 `still`，别的是 `resting`。
    public init(instance state: InstanceState) {
        switch state {
        case .paused: self = .sleeping
        case .archived, .deleted: self = .still
        case .provisioning, .running, .unknown: self = .resting
        }
    }

    /// 一个 Botin 此刻的状态（首页的行、资料页、`AppModel.faceMood(for:)` 都按它）：基本和首页那一行的角标同一个说法
    /// （`HomeRowPreview.faceMood`）——有运行在等用户时按最近在等的那个，有没结束的运行时按最近那个，都没有时按实例的状态。
    /// 只有一处不一样：在等用户的之外还有没结束的运行（排队、启动、运行、重试等待）时是 `active`，哪怕角标画的是在等的那个
    /// （用户定的“运行中也要随机展示动作”：有在跑的就会动）。
    public init(state: InstanceState, activity: InstanceActivity) {
        let preview = HomeRowPreview(state: state, activity: activity)
        if case .waiting = preview, activity.activeRuns > activity.waitingRuns {
            self = .active
        } else {
            self = preview.faceMood
        }
    }
}

/// 一个小动作：有任务在跑时随机做的（跳、歪头、笑、点头），在等用户时定时做的（连跳两下），和界面触发的反应（点一下、
/// 挑了形状颜色笑一下）。每个都是从开始算起的时间的纯函数，开头和结尾都正好是原来的样子（`BotinFaceLife.Pose.adding(_:at:)`）。
public enum BotinFaceGesture: Sendable, Hashable, CaseIterable {
    /// 跳一下（0.62 秒）：0.1 秒蹲下（压扁），起跳时拉长，抛物线上去 0.075 再落下，落地压扁一下、弹回来；空中眯成笑眼（0.6）。
    case hop
    /// 往左歪头（1.3 秒）：0.25 秒歪过去 0.14 弧度，停 0.7 秒，0.35 秒回正；眼睛跟着往左看。
    case tiltLeft
    /// 往右歪头，同上。
    case tiltRight
    /// 笑一下（1.2 秒）：0.18 秒弯成笑眼，停 0.7 秒，0.32 秒变回来；开头身体轻轻往上弹一下（0.015）。
    case happy
    /// 点头（0.9 秒）：身体往下点两下（0.02），眼睛跟着往下看。
    case nod
    /// 点了一下头像、选中了一格（0.9 秒）：前 0.62 秒和 `hop` 一样跳一下，眼睛 0.15 秒弯成笑眼，到 0.9 秒变回来。
    case tap
    /// 连着小跳两下叫人（0.62 秒，在等用户时每 3.4 秒一次）：每下 0.28 秒，是 `hop` 的身体曲线压到 0.28 秒、高度和压扁拉长
    /// 按 0.035 / 0.075 缩小（跳 0.035 高），两下之间隔 0.06 秒不动；不眯眼（在等用户时眼睛一直睁大），也不改看向。
    case doubleHop

    /// 做一遍多久（秒）。
    public var duration: TimeInterval {
        switch self {
        case .hop: BotinFaceLife.Timing.hopDuration
        case .tiltLeft, .tiltRight: BotinFaceLife.Timing.tiltDuration
        case .happy: BotinFaceLife.Timing.happyDuration
        case .nod: BotinFaceLife.Timing.nodDuration
        case .tap: BotinFaceLife.Timing.tapDuration
        case .doubleHop: BotinFaceLife.Timing.doubleHopDuration
        }
    }
}

/// 界面触发的一次反应（点了一下头像、选中了一格、挑了形状或颜色）：从 `start` 开始把一个小动作做一遍，叠在这时的样子上。
/// 记的是开始的时刻，样子照样是时间的纯函数（界面把最近的几次放在 `@State` 里，见 ThinktinUI 的 `BotinFace`）。
public struct BotinFaceReaction: Sendable, Hashable {
    public var gesture: BotinFaceGesture
    /// 开始的时刻（`Date.timeIntervalSinceReferenceDate`），可以在将来（挑了形状 0.3 秒后再笑）。
    public var start: TimeInterval

    public init(_ gesture: BotinFaceGesture, start: TimeInterval) {
        self.gesture = gesture
        self.start = start
    }

    /// 结束的时刻：这一刻起不再改样子。
    public var end: TimeInterval { start + gesture.duration }

    /// 这次反应在动的窗口；开始的时刻不是有限数、或者离 2001 年太远（`BotinFaceLife` 算不准）时没有。
    public var window: ClosedRange<TimeInterval>? {
        BotinFaceLife.supports(start) ? start...end : nil
    }

    /// 时刻 `t` 正在做（开始的那一刻算，结束的那一刻不算；和窗口一样按 `end` 比）。
    public func isPlaying(at t: TimeInterval) -> Bool {
        window != nil && t >= start && t < end
    }

    /// 最多留几次：连着点的时候前几次还没做完，叠在一起做（身体的挪动相加，最后夹在范围里）。
    public static let limit = 4

    /// 加上一次新的：已经做完的（结束不晚于 `now`）去掉，最多留 `limit` 次（去掉最早的）。
    public static func adding(
        _ reaction: BotinFaceReaction, to reactions: [BotinFaceReaction], now: TimeInterval
    ) -> [BotinFaceReaction] {
        let unfinished = reactions.filter { $0.window != nil && $0.end > now } + [reaction]
        return Array(unfinished.suffix(limit))
    }

    /// 还没做完的（正在做的、还没开始的）里最晚结束的时刻；都做完了（或者都算不准）是 nil。界面在这之前给时间线，
    /// 之后换回不动的脸。
    public static func pendingEnd(_ reactions: [BotinFaceReaction], now: TimeInterval) -> TimeInterval? {
        reactions.filter { $0.window != nil && $0.end > now }.map(\.end).max()
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
        /// 眼睛睁开多少：1 全睁开，0.1 闭上（留一条缝）。笑眼也一样压扁。
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
        /// 笑眼：0 平常的椭圆，1 弯成“∩”（上半边不变，下半边换成上半边压到 55% 高，整只眼睛往上提一点），中间的按点插值。
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

    /// 各项能到的范围（`Pose.clamped()` 按它夹，画的时候也按它夹）：身体往上下挪最多 0.08、压扁拉长在 0.88 到 1.10 之间。
    /// 身体会冒出头像的方框（测试量过）：跳一下时起跳的拉长（1.06）和往上挪叠在一起，顶到方框上沿的形状（圆、圆角方形、
    /// 四角星、花朵、花边圆）的头顶冒出上沿约 0.102 倍边长（0.17 秒前后）；歪头时圆角方形的角翘出约 0.026；点头时脚底往下
    /// 0.02；蹲下、落地时两边撑出 0.04。连着点几下（反应叠在一起）、歪着头时被点，加起来能冒出 0.14 到 0.18，所以画的时候
    /// 头顶最多冒出 `lift`，多了整个往下挪回来（ThinktinUI 的 `BotinFaceShape.transform`）。头像上沿贴着会切掉内容的边时
    /// （贴边的列表行：资料页头部、编辑页顶上），上面至少留 `lift` 倍边长。
    public enum Limits {
        public static let lid: ClosedRange<Double> = 0.1...1
        public static let bodyOffset = 0.08
        public static let squash: ClosedRange<Double> = 0.88...1.10
        public static let tilt = 0.15
        public static let eyeScale: ClosedRange<Double> = 0.8...1.12
        /// 画出来的身体头顶最多冒出方框上沿多少（单位边长）：一次跳一下正好够得着（最多约 0.102，被削掉的不到 0.002、
        /// 约 0.03 秒，看不出来），80pt 的头像是 8pt。
        public static let lift = 0.10
    }

    /// 不动的样子：看正前方、眼睛睁着（没有任务在跑、关了动效、截图时用）。
    public static let restPose = Pose()

    /// 这种状态不动时的表情（`resting`、`sleeping`、`still` 一直是这样，`active`、`waiting` 在动的窗口之间是这样；关了动效时
    /// 都是这样）：等用户时眼睛睁大（1.12 倍）往上看（-0.35），暂停、归档时闭着眼（留 0.12 的缝，放大 1.12 倍，看着比平时
    /// 宽一点），别的是不动的样子。
    public static func restPose(for mood: BotinFaceMood) -> Pose {
        switch mood {
        case .resting, .active: restPose
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

    /// 时刻 `t`（`Date.timeIntervalSinceReferenceDate`）、状态 `mood` 下的样子，叠上正在做的反应：`active` 时眨眼、看向、
    /// 随机的小动作，`waiting` 时在 `restPose(for: .waiting)` 上眨眼、连跳两下，别的状态是 `restPose(for:)`。
    ///
    /// `since` 是这次进入 `mood` 的时刻（界面记下的，ThinktinUI 的 `BotinFace`；默认 -∞ 是一直在这个状态）：`active`、
    /// `waiting` 时这以前开始的眨眼、转眼、小动作、连跳都不算，第一次转眼从正前方转过去，所以 `since` 那一刻（和以前）正好是
    /// 这种状态不动的样子，之后接着连续地动——刚开始跑、刚选中、刚开始等用户时不会一下子跳到半路。别的状态用不着它。
    /// NaN 当 -∞。
    ///
    /// `t` 不是有限数、或者离 2001 年太远（超过 `Timing.supportedRange`）时返回 `restPose(for:)`。
    public func pose(
        at t: TimeInterval, mood: BotinFaceMood, since: TimeInterval = -.infinity, reactions: [BotinFaceReaction] = []
    ) -> Pose {
        guard Self.supports(t) else { return Self.restPose(for: mood) }
        let since = Self.sanitized(since)
        var pose = Self.restPose(for: mood)
        if mood.isAlive, t >= since {
            pose.lid = lid(at: t, since: since)
            switch mood {
            case .active: addActiveMotion(to: &pose, at: t, since: since)
            case .waiting: Self.addWaitingMotion(to: &pose, at: t, since: since)
            case .resting, .sleeping, .still: break
            }
        }
        for reaction in reactions where reaction.isPlaying(at: t) {
            pose.add(reaction.gesture, at: t - reaction.start)
        }
        return pose.clamped()
    }

    /// 在跑：看向、这个槽里的随机小动作（眨眼 `pose(at:)` 已经算了）。
    private func addActiveMotion(to pose: inout Pose, at t: TimeInterval, since: TimeInterval) {
        let gaze = gaze(at: t, since: since)
        pose.gazeX = gaze.x
        pose.gazeY = gaze.y
        // 和窗口一样按结尾比（`blinkLid` 的说明）；做小动作时眼睛不自己转（转眼挪到小动作做完，`glanceStart`），
        // 歪头、点头时看向由小动作带着走。
        if let gesture = gesture(slot: Self.slot(of: t, length: Timing.gestureSlot)), gesture.start >= since,
            t >= gesture.start, t < gesture.start + gesture.kind.duration
        {
            pose.add(gesture.kind, at: t - gesture.start)
        }
    }

    /// 在等用户：这个槽里的连跳两下（眼睛睁大往上看是 `restPose(for: .waiting)`，眨眼 `pose(at:)` 已经算了）；`since`
    /// 以前开始的不算。和窗口一样按结尾比。
    private static func addWaitingMotion(to pose: inout Pose, at t: TimeInterval, since: TimeInterval) {
        let start = Self.doubleHopStart(slot: Self.slot(of: t, length: Timing.waitingSlot))
        guard start >= since, t >= start, t < start + BotinFaceGesture.doubleHop.duration else { return }
        pose.add(.doubleHop, at: t - start)
    }

    /// 时刻 `t` 以后（含正在进行的）最早的一个动的窗口：上界大于 `t` 的窗口里开始得最早的那个（`t` 在窗口里就是这个
    /// 窗口）。窗口外面样子不变，界面只在窗口里逐帧重画。`since` 和 `pose(at:mood:since:reactions:)` 的一样：`active`、
    /// `waiting` 时它以前开始的窗口不算。往后再也不会动了（不是 `active`、`waiting`，也没有还没做完的反应）时是 +∞…+∞。
    /// `t` 不是有限数、或者离 2001 年太远时返回从 `t` 开始的空窗口（`t` 是 NaN 时是 +∞）：调用方看到上界不大于 `t` 就别再等
    /// 下一个窗口了。
    public func nextActiveWindow(
        after t: TimeInterval, mood: BotinFaceMood, since: TimeInterval = -.infinity,
        reactions: [BotinFaceReaction] = []
    ) -> ClosedRange<TimeInterval> {
        guard Self.supports(t) else { return t.isNaN ? .infinity ... .infinity : t...t }
        let since = Self.sanitized(since)
        var best: ClosedRange<TimeInterval>?
        func consider(_ window: ClosedRange<TimeInterval>?) {
            guard let window, window.upperBound > t else { return }
            if let current = best, current.lowerBound <= window.lowerBound { return }
            best = window
        }
        // `since` 太远（算不准）时当它永远不来：`active`、`waiting` 也一直是不动的样子。
        if mood.isAlive, since <= Timing.supportedRange {
            consider(Self.firstWindow(after: t, since: since, nextBlinkWindow(after:)))
            switch mood {
            case .active:
                consider(Self.firstWindow(after: t, since: since, nextGlanceWindow(after:)))
                consider(Self.firstWindow(after: t, since: since, nextGestureWindow(after:)))
            case .waiting:
                consider(Self.firstWindow(after: t, since: since, Self.nextDoubleHopWindow(after:)))
            case .resting, .sleeping, .still: break
            }
        }
        for reaction in reactions {
            consider(reaction.window)
        }
        return best ?? .infinity ... .infinity
    }

    /// `find` 在 `t`（和 `since` 里晚的那个）以后找到的窗口里，第一个不早于 `since` 开始的：进入 `active` 以前开始的
    /// 那些不做，跳过。`find(after: x)` 给的窗口上界都大于 `x`，所以一次次往后找总会停下（一般一两次）。
    private static func firstWindow(
        after t: TimeInterval, since: TimeInterval, _ find: (TimeInterval) -> ClosedRange<TimeInterval>?
    ) -> ClosedRange<TimeInterval>? {
        var window = find(Swift.max(t, since))
        while let current = window, current.lowerBound < since {
            window = find(current.upperBound)
        }
        return window
    }

    /// NaN 的 `since` 当 -∞（一直在这个状态）。
    private static func sanitized(_ since: TimeInterval) -> TimeInterval {
        since.isNaN ? -.infinity : since
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

        /// 随机的小动作：6 秒一个槽，70% 的槽里有一个，开始的时刻在槽头后 0.8 到 4.3 秒（最长的歪头 1.3 秒，最晚在槽头后
        /// 5.6 秒做完，和下一个槽的不会碰上）。做哪个：跳 30%、歪头 25%（往左往右各一半）、笑 25%、点头 20%。
        static let gestureSlot: TimeInterval = 6
        static let gestureChance = 0.7
        static let gestureEarliest: TimeInterval = 0.8
        static let gestureSpread: TimeInterval = 3.5
        static let hopShare = 0.30
        static let tiltShare = 0.25
        static let happyShare = 0.25

        /// 跳一下：时长、跳多高；起跳、落地的时刻（中间是抛物线）。
        static let hopDuration: TimeInterval = 0.62
        static let hopHeight = 0.075
        static let hopTakeOff: TimeInterval = 0.10
        static let hopLanding: TimeInterval = 0.42
        /// 歪头：时长、歪多少（弧度）、眼睛跟着往那边看多远。
        static let tiltDuration: TimeInterval = 1.3
        static let tiltAngle = 0.14
        static let tiltGaze = 0.5
        /// 笑一下：时长；身体往上弹多高、在 0.1 到 0.3 秒之间。
        static let happyDuration: TimeInterval = 1.2
        static let happyBounce = 0.015
        static let happyBounceStart: TimeInterval = 0.1
        static let happyBounceLength: TimeInterval = 0.2
        /// 点头：时长；往下点多少、眼睛往下看多少，两下的中心、每下多长。
        static let nodDuration: TimeInterval = 0.9
        static let nodDepth = 0.02
        static let nodGaze = 0.4
        static let nodCenters: [TimeInterval] = [0.18, 0.58]
        static let nodLength: TimeInterval = 0.3
        /// 点了一下：时长（前 0.62 秒是跳一下）。
        static let tapDuration: TimeInterval = 0.9

        /// 等用户：眼睛睁多大、往上看多少。
        static let waitingEyeScale = 1.12
        static let waitingGazeY = -0.35
        /// 等用户时叫人：3.4 秒一个槽，槽头后 0.4 秒连着小跳两下（不随机：所有在等的 Botin 一起跳，节奏好认）。每下 0.28 秒、
        /// 跳 0.035 高，两下之间隔 0.06 秒；一共 0.62 秒，最晚在槽头后 1.02 秒跳完，碰不上下一个槽的。
        static let waitingSlot: TimeInterval = 3.4
        static let doubleHopOffset: TimeInterval = 0.4
        static let doubleHopLength: TimeInterval = 0.28
        static let doubleHopGap: TimeInterval = 0.06
        static let doubleHopHeight = 0.035
        static let doubleHopDuration: TimeInterval = 2 * doubleHopLength + doubleHopGap
        /// 睡着、归档：闭着的眼睛留多少缝、放大多少（闭着的眼睛只剩一条缝，看着就是宽了一点）。
        static let sleepingLid = 0.12
        static let sleepingEyeScale = 1.12

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

    /// 眼睛睁开多少：前后三个槽里的眨眼取最小（同一时刻最多一次眨眼在进行）；`since` 以前开始的不算。小动作时照样眨眼。
    func lid(at t: TimeInterval, since: TimeInterval) -> Double {
        let slot = Self.slot(of: t, length: Timing.blinkSlot)
        var lid = 1.0
        for neighbour in (slot - 1)...(slot + 1) {
            let starts = blinkStarts(slot: neighbour)
            if starts.first >= since {
                lid = min(lid, Self.blinkLid(at: t, start: starts.first))
            }
            if let second = starts.second, second >= since {
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

    /// 槽 `slot` 里眼睛开始转的时刻：槽头往后随机 0 到 0.9 秒；这 0.16 秒要是和小动作碰上，就等小动作做完正好接着转
    /// （做小动作时眼睛不自己转）。挪过以后最晚在槽头后 2.36 秒转完、比下一个槽的早，也碰不上下一个小动作（两个小动作
    /// 之间至少隔 1.2 秒），所以每个槽还是正好转一次、按槽的顺序转。
    func glanceStart(slot: Int64) -> TimeInterval {
        let planned = Double(slot) * Timing.glanceSlot + random(slot: slot, stream: .glanceOffset) * Timing.glanceJitter
        let first = Self.slot(of: planned, length: Timing.gestureSlot)
        let last = Self.slot(of: planned + Timing.glanceDuration, length: Timing.gestureSlot)
        for candidate in first...last {
            guard let gesture = gesture(slot: candidate) else { continue }
            let end = gesture.start + gesture.kind.duration
            if planned < end, planned + Timing.glanceDuration > gesture.start { return end }
        }
        return planned
    }

    /// 槽 `slot` 里眼睛转到哪儿：40% 看回正前方，其余随便一个方向、0.55 到满幅，上下的幅度小一点。
    func glanceTarget(slot: Int64) -> (x: Double, y: Double) {
        guard random(slot: slot, stream: .lookAhead) >= Timing.lookAheadChance else { return (0, 0) }
        let angle = 2 * Double.pi * random(slot: slot, stream: .glanceAngle)
        let reach = Timing.minimumReach + Timing.reachSpread * random(slot: slot, stream: .glanceReach)
        return (Self.clampUnit(reach * cos(angle)), Self.clampUnit(Timing.verticalReach * reach * sin(angle)))
    }

    /// 看向：最近一次开始转（开始时刻不晚于 `t` 的最后一个槽）从上一次的落点转到这次的落点（三次缓出），转完停住。
    /// `since` 以前开始的转眼不算：那以后还没转过时看正前方，第一次从正前方转过去。
    func gaze(at t: TimeInterval, since: TimeInterval) -> (x: Double, y: Double) {
        let slot = Self.slot(of: t, length: Timing.glanceSlot)
        // 这个槽的还没开始就是上一个槽的（上一个槽的最晚在它的槽头后 2.36 秒，早于这个槽头）。
        let latest = glanceStart(slot: slot) <= t ? slot : slot - 1
        let start = glanceStart(slot: latest)
        guard start >= since else { return (0, 0) }
        let target = glanceTarget(slot: latest)
        // 和 `blinkLid` 一样按窗口的上界比，窗口一结束就正好停在落点上。
        guard t < start + Timing.glanceDuration else { return target }
        let from: (x: Double, y: Double) =
            glanceStart(slot: latest - 1) >= since ? glanceTarget(slot: latest - 1) : (0, 0)
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

    // MARK: - 随机的小动作

    /// 槽 `slot` 里的小动作（没有就是 nil）：开始的时刻、做哪个。
    func gesture(slot: Int64) -> (start: TimeInterval, kind: BotinFaceGesture)? {
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

    /// 这个槽和后面三个槽里第一个还没做完的小动作的窗口；都没有时是 nil（这时 6 秒以内一定有眨眼、转眼的窗口，
    /// `nextActiveWindow` 用不着更远的）。小动作不跨槽，前一个槽的在这个槽头以前就做完了。
    func nextGestureWindow(after t: TimeInterval) -> ClosedRange<TimeInterval>? {
        let slot = Self.slot(of: t, length: Timing.gestureSlot)
        for candidate in slot...(slot + 3) {
            guard let gesture = gesture(slot: candidate) else { continue }
            let end = gesture.start + gesture.kind.duration
            if end > t { return gesture.start...end }
        }
        return nil
    }

    // MARK: - 在等用户时叫人

    /// 第 `slot` 个槽（3.4 秒一个）里连跳两下开始的时刻：槽头后 0.4 秒。
    static func doubleHopStart(slot: Int64) -> TimeInterval {
        Double(slot) * Timing.waitingSlot + Timing.doubleHopOffset
    }

    /// 这个槽里还没跳完的那次；跳完了是下一个槽的（它在槽头 0.4 秒以后，一定在 `t` 以后）。
    static func nextDoubleHopWindow(after t: TimeInterval) -> ClosedRange<TimeInterval> {
        let slot = Self.slot(of: t, length: Timing.waitingSlot)
        let duration = BotinFaceGesture.doubleHop.duration
        let start = Self.doubleHopStart(slot: slot)
        if start + duration > t { return start...(start + duration) }
        let next = Self.doubleHopStart(slot: slot + 1)
        return next...(next + duration)
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
    /// 伸缩相乘，笑眼取大的，看向往动作要看的方向拉。`u` 不在 [0, 时长) 里时不变；每条曲线在 0 和时长处都是不变。
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
        case .doubleHop:
            let scale = Timing.doubleHopHeight / Timing.hopHeight
            for start in [0, Timing.doubleHopLength + Timing.doubleHopGap]
            where u >= start && u < start + Timing.doubleHopLength {
                applyBody(Self.hopBody(at: (u - start) * Timing.hopDuration / Timing.doubleHopLength, scale: scale))
            }
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
        }
    }

    private mutating func applyBody(_ body: (offset: Double, squashX: Double, squashY: Double)) {
        bodyOffsetY += body.offset
        squashX *= body.squashX
        squashY *= body.squashY
    }

    /// 跳一下的身体（`u` 秒，0 到 0.62；0.62 以后不变）：0–0.10 蹲下（竖着压到 0.90、横着撑到 1.08，先快后慢），
    /// 0.10–0.14 一下子拉长（1.06 / 0.96），到 0.26（最高点）缓回 1；0.10–0.42 抛物线上去 0.075 再落下；0.42–0.47 落地
    /// 压扁（0.94 / 1.05），停到 0.50，0.50–0.62 弹回 1（先快后慢）。都是连续的。`scale` 把高度和压扁拉长（离 1 多远）
    /// 一起缩小（连跳两下的小跳用）。
    static func hopBody(at u: TimeInterval, scale: Double = 1) -> (offset: Double, squashX: Double, squashY: Double) {
        typealias Timing = BotinFaceLife.Timing
        var offset = 0.0
        if u > Timing.hopTakeOff, u < Timing.hopLanding {
            let p = (u - Timing.hopTakeOff) / (Timing.hopLanding - Timing.hopTakeOff)
            offset = -Timing.hopHeight * 4 * p * (1 - p)
        }
        return (offset * scale, 1 + (hopSquashX.value(at: u) - 1) * scale, 1 + (hopSquashY.value(at: u) - 1) * scale)
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
