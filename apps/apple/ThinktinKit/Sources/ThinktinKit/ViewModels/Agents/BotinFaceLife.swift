import Foundation

// Botin 头像上的两只眼睛什么时候眨、往哪儿看（docs/ios-ui-redesign.md 4.4.4）。画法在 ThinktinUI 的 `BotinFace`，
// 这里只管时间：一个 Botin 一个种子（名字的散列），某一刻的样子只由种子和时间算出来，不存时钟、运行时不取随机数，
// 每次算都是常数时间（按时间分槽，每个槽的随机数现算，不预先排一张会用完的表）。
//
// 眨眼和看向都只在很短的“动的窗口”里变（眨一次 0.2 秒、转一次眼 0.16 秒），窗口外面样子不变：界面只在窗口里逐帧
// 重画，平时一帧都不画（`BotinFaceSchedule`）。时长、间隔都是我们自己定的。

/// 一个 Botin 的眨眼、看向：纯函数（种子 + 时间 → 样子），同一个名字在哪台设备上、哪次启动都一样。
public struct BotinFaceLife: Sendable, Hashable {
    /// 某一刻的样子。
    public struct Pose: Sendable, Hashable {
        /// 往左右看：-1 最左，0 正前方，1 最右。
        public var gazeX: Double
        /// 往上下看：-1 最上，0 正前方，1 最下。
        public var gazeY: Double
        /// 眼睛睁开多少：1 全睁开，0.1 闭上（留一条缝）。
        public var lid: Double

        public init(gazeX: Double = 0, gazeY: Double = 0, lid: Double = 1) {
            self.gazeX = gazeX
            self.gazeY = gazeY
            self.lid = lid
        }
    }

    /// 不动的样子：看正前方、眼睛睁着（关了动效、截图、选形状的格子里用）。
    public static let restPose = Pose()

    /// 种子：决定这个 Botin 什么时候眨眼、往哪儿看。
    public let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
    }

    /// 按名字取种子：去掉首尾空白、转小写后的 FNV-1a 散列（64 位，跨进程、跨设备稳定；不用 `Hasher`，它每次启动的
    /// 种子不一样）。同一个 Botin 在列表和标题上同时出现时一起眨眼。
    public init(name: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        self.init(seed: hash)
    }

    /// 时刻 `t`（`Date.timeIntervalSinceReferenceDate`）的样子。`t` 不是有限数、或者离 2001 年太远（超过
    /// `Timing.supportedRange`）时返回 `restPose`。
    public func pose(at t: TimeInterval) -> Pose {
        guard Self.supports(t) else { return Self.restPose }
        let gaze = gaze(at: t)
        return Pose(gazeX: gaze.x, gazeY: gaze.y, lid: lid(at: t))
    }

    /// 时刻 `t` 以后（含正在进行的）最早的一个动的窗口：上界大于 `t` 的窗口里开始得最早的那个（`t` 在窗口里就是这个
    /// 窗口）。窗口外面样子不变，界面只在窗口里逐帧重画。`t` 不是有限数、或者离 2001 年太远时返回从 `t` 开始的空窗口
    /// （`t` 是 NaN 时是 +∞）：调用方看到上界不大于 `t` 就别再等下一个窗口了。
    public func nextActiveWindow(after t: TimeInterval) -> ClosedRange<TimeInterval> {
        guard Self.supports(t) else { return t.isNaN ? .infinity ... .infinity : t...t }
        let blink = nextBlinkWindow(after: t)
        let glance = nextGlanceWindow(after: t)
        return glance.lowerBound < blink.lowerBound ? glance : blink
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
    /// 两种算法差一个浮点数的最小单位，窗口刚结束的那一刻会差一点没睁全）。
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
