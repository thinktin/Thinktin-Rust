import Foundation
import Testing

@testable import ThinktinKit

// Botin 头像的脸怎么动（docs/ios-ui-redesign.md 4.4.4）：只由种子、状态、反应和时间决定；只有有任务在跑（`active`）的会动，
// 眨眼、看向、随机的小动作的范围、频率、窗口都对；别的状态一动不动（在等用户的 `waiting` 也是：用户 2026-11-09 定的“不运行中的
// 会话不用动”，只睁大眼睛往上看）；小动作和反应两头接得上，叠在每种状态不动的表情上也是；奇怪的时间不崩。

@Suite("Botin 头像的眨眼、看向、小动作")
struct BotinFaceLifeTests {
    private typealias Pose = BotinFaceLife.Pose

    /// 2026 年 11 月前后的时间（`Date.timeIntervalSinceReferenceDate`），和真机上的量级一样。
    private let base: TimeInterval = 815_000_000
    private let seeds: [UInt64] = [0, 1, 42, 0xDEAD_BEEF, .max, BotinFaceLife(name: "周报助手").seed]
    /// 不会自己动的状态（在等用户的 2026-11-09 起也不动）。
    private let staticMoods: [BotinFaceMood] = [.resting, .waiting, .sleeping, .still]

    @Test("同一个种子、同一个状态永远一样；名字的种子是 FNV-1a 64 位，不分大小写、不管首尾空白")
    func deterministic() {
        // 期望值是在别处（Python）按同样的算法独立算出来的，散列改了这里会失败。
        #expect(BotinFaceLife(name: "周报助手").seed == 0x6DFC_DFA8_E38F_1B64)
        #expect(BotinFaceLife(name: "Codex").seed == 0x2FFB_778D_FAE5_4384)
        #expect(BotinFaceLife(name: "").seed == 0xCBF2_9CE4_8422_2325)
        #expect(BotinFaceLife(name: "  CODEX \n") == BotinFaceLife(name: "codex"))
        let reactions = [BotinFaceReaction(.tap, start: base + 3), BotinFaceReaction(.happy, start: base + 50)]
        for seed in seeds {
            let a = BotinFaceLife(seed: seed)
            let b = BotinFaceLife(seed: seed)
            for mood in BotinFaceMood.allCases {
                for i in 0..<1_000 {
                    let t = base + Double(i) * 0.0731
                    #expect(a.pose(at: t, mood: mood) == b.pose(at: t, mood: mood))
                    #expect(a.nextActiveWindow(after: t, mood: mood) == b.nextActiveWindow(after: t, mood: mood))
                    #expect(
                        a.pose(at: t, mood: mood, reactions: reactions)
                            == b.pose(at: t, mood: mood, reactions: reactions))
                }
            }
        }
    }

    @Test("不同的种子样子不一样")
    func seedsDiffer() {
        let a = BotinFaceLife(name: "周报助手")
        let b = BotinFaceLife(name: "翻译")
        var different = 0
        for i in 0..<2_000 {
            let t = base + Double(i) * 0.0731
            if a.pose(at: t, mood: .active) != b.pose(at: t, mood: .active) { different += 1 }
        }
        #expect(different > 1_000)
        #expect(a.nextActiveWindow(after: base, mood: .active) != b.nextActiveWindow(after: base, mood: .active))
    }

    @Test("在跑的时候 600 秒里眨眼的次数说得过去：大约 600 / 4.2 次，加上偶尔连眨的")
    func blinkCount() {
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            var blinks = 0
            var wasOpen = true
            var minimum = 1.0
            for i in 0...(600 * 240) {
                let lid = life.pose(at: base + Double(i) / 240, mood: .active).lid
                if wasOpen, lid < 1 { blinks += 1 }
                wasOpen = lid == 1
                minimum = min(minimum, lid)
            }
            #expect(blinks >= 140 && blinks <= 190, "\(seed): \(blinks)")
            // 600 秒有 142 到 143 个槽，多出来的是连眨；闭眼时真的闭到 0.1。
            #expect(blinks > 143, "\(seed): \(blinks)")
            #expect(abs(minimum - 0.1) < 0.005, "\(seed): \(minimum)")
        }
    }

    @Test("范围：眼睛睁开 0.1 到 1，看向 -1 到 1、也真的往四个方向看；身体挪动不超过 0.08，伸缩在 0.88 到 1.10")
    func ranges() {
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            var extremes = (left: 0.0, right: 0.0, up: 0.0, down: 0.0)
            var outOfRange: [TimeInterval] = []
            var body = (offset: 0.0, squashLow: 1.0, squashHigh: 1.0, tilt: 0.0, smile: 0.0)
            for i in 0..<20_000 {
                let t = base + Double(i) * 0.0517
                let pose = life.pose(at: t, mood: .active)
                let inRange =
                    pose.lid >= 0.1 && pose.lid <= 1 && abs(pose.gazeX) <= 1 && abs(pose.gazeY) <= 1
                    && abs(pose.bodyOffsetY) <= 0.08 && pose.squashX >= 0.88 && pose.squashX <= 1.10
                    && pose.squashY >= 0.88 && pose.squashY <= 1.10 && abs(pose.tilt) <= 0.15
                    && pose.smile >= 0 && pose.smile <= 1 && pose.eyeScale == 1
                if !inRange { outOfRange.append(t) }
                extremes = (
                    min(extremes.left, pose.gazeX), max(extremes.right, pose.gazeX), min(extremes.up, pose.gazeY),
                    max(extremes.down, pose.gazeY)
                )
                body = (
                    max(body.offset, abs(pose.bodyOffsetY)), min(body.squashLow, pose.squashX, pose.squashY),
                    max(body.squashHigh, pose.squashX, pose.squashY), max(body.tilt, abs(pose.tilt)),
                    max(body.smile, pose.smile)
                )
            }
            #expect(outOfRange.isEmpty, "\(seed): \(outOfRange.prefix(5))")
            #expect(extremes.left < -0.5 && extremes.right > 0.5, "\(seed)")
            #expect(extremes.up < -0.4 && extremes.down > 0.4, "\(seed)")
            // 随机的小动作真的做了：跳起来、歪头、笑。
            #expect(body.offset > 0.05 && body.tilt > 0.1 && body.smile > 0.9, "\(seed): \(body)")
            #expect(body.squashLow < 0.95 && body.squashHigh > 1.03, "\(seed): \(body)")
        }
    }

    @Test("随机的小动作：10 分钟里大约 600 / 6 × 0.7 ≈ 70 个，四种都有，一个做完下一个才开始，都在自己的槽里")
    func gestureRate() {
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            let first = BotinFaceLife.slot(of: base, length: 6)
            var gestures: [(start: TimeInterval, kind: BotinFaceGesture)] = []
            var counted = 0
            // 100 个槽算个数；`base` 不在槽头上，多看一个槽，下面按样子查的 600 秒都盖得住。
            for slot in first...(first + 100) {
                if let gesture = life.gesture(slot: slot) {
                    gestures.append(gesture)
                    if slot < first + 100 { counted += 1 }
                    // 在槽头后 0.8 到 4.3 秒开始，最晚在槽尾前做完。
                    let offset = gesture.start - Double(slot) * 6
                    #expect(offset >= 0.8 - 1e-6 && offset <= 4.3 + 1e-6, "\(seed) \(slot): \(offset)")
                    #expect(gesture.start + gesture.kind.duration < Double(slot + 1) * 6, "\(seed) \(slot)")
                }
            }
            #expect(counted >= 50 && counted <= 90, "\(seed): \(counted)")
            let kinds = Set(gestures.map(\.kind))
            #expect(kinds.contains(.hop) && kinds.contains(.happy) && kinds.contains(.nod), "\(seed): \(kinds)")
            #expect(kinds.contains(.tiltLeft) || kinds.contains(.tiltRight), "\(seed): \(kinds)")
            #expect(!kinds.contains(.tap), "\(seed): 点一下只是反应")
            for (a, b) in zip(gestures, gestures.dropFirst()) {
                #expect(a.start + a.kind.duration < b.start, "\(seed): \(a) \(b)")
            }
            // 从样子上看也一样：身体动了、笑了的时候一定在某个小动作的窗口里。
            var outside: [TimeInterval] = []
            for i in 0..<(600 * 60) {
                let t = base + Double(i) / 60
                let pose = life.pose(at: t, mood: .active)
                let moved =
                    pose.bodyOffsetY != 0 || pose.squashX != 1 || pose.squashY != 1 || pose.tilt != 0 || pose.smile != 0
                if moved, !gestures.contains(where: { t >= $0.start && t < $0.start + $0.kind.duration }) {
                    outside.append(t)
                }
            }
            #expect(outside.isEmpty, "\(seed): \(outside.prefix(5))")
        }
    }

    @Test("做小动作时眼睛不自己转：转眼的窗口和小动作的窗口不重叠，挪过的转眼正好在小动作做完时开始")
    func glancesPauseDuringGestures() {
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            let firstGlance = BotinFaceLife.slot(of: base, length: 2.8)
            var postponed = 0
            var overlaps: [Int64] = []
            var previous = -Double.infinity
            for slot in firstGlance..<(firstGlance + 300) {
                let start = life.glanceStart(slot: slot)
                // 还在自己的槽里、按顺序。
                #expect(start >= Double(slot) * 2.8 - 1e-6 && start + 0.16 < Double(slot + 1) * 2.8, "\(seed) \(slot)")
                #expect(start > previous)
                previous = start
                let gestureSlot = BotinFaceLife.slot(of: start, length: 6)
                for candidate in (gestureSlot - 1)...(gestureSlot + 1) {
                    guard let gesture = life.gesture(slot: candidate) else { continue }
                    let end = gesture.start + gesture.kind.duration
                    if start < end, start + 0.16 > gesture.start { overlaps.append(slot) }
                    if start == end { postponed += 1 }
                }
            }
            #expect(overlaps.isEmpty, "\(seed): \(overlaps.prefix(5))")
            #expect(postponed > 5, "\(seed): \(postponed)")
            // 跳、笑的时候看向一点都不变（歪头、点头时由小动作带着走）。
            let first = BotinFaceLife.slot(of: base, length: 6)
            for slot in first..<(first + 50) {
                guard let gesture = life.gesture(slot: slot), gesture.kind == .hop || gesture.kind == .happy else {
                    continue
                }
                let atStart = life.pose(at: gesture.start, mood: .active)
                var u = 0.0
                while u < gesture.kind.duration {
                    let pose = life.pose(at: gesture.start + u, mood: .active)
                    #expect(pose.gazeX == atStart.gazeX && pose.gazeY == atStart.gazeY, "\(seed) \(slot) \(u)")
                    u += 1.0 / 60
                }
            }
        }
    }

    @Test("窗口外面不动：眼睛全睁开，样子一直是同一个")
    func constantBetweenWindows() {
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            var t = base
            var gaps = 0
            var moved: [TimeInterval] = []
            while t < base + 120 {
                let window = life.nextActiveWindow(after: t, mood: .active)
                if t < window.lowerBound {
                    gaps += 1
                    let pose = life.pose(at: t, mood: .active)
                    if pose.lid != 1 || pose.smile != 0 || pose.bodyOffsetY != 0 { moved.append(t) }
                    var s = t
                    while s < window.lowerBound {
                        if life.pose(at: s, mood: .active) != pose { moved.append(s) }
                        s += 1.0 / 97
                    }
                    if life.pose(at: window.lowerBound.nextDown, mood: .active) != pose {
                        moved.append(window.lowerBound)
                    }
                }
                t = window.upperBound
            }
            #expect(moved.isEmpty, "\(seed): \(moved.prefix(5))")
            #expect(gaps > 40, "\(seed): \(gaps)")
        }
    }

    @Test("下一个窗口：上界在 t 以后，长短对（转眼 0.16 到歪头 1.3 秒），t 和下界之间样子一点都没变")
    func nextWindowInvariants() {
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            var broken: [TimeInterval] = []
            var moved: [TimeInterval] = []
            for i in 0..<1_500 {
                let t = base + Double(i) * 0.1373
                let window = life.nextActiveWindow(after: t, mood: .active)
                let length = window.upperBound - window.lowerBound
                // 接着找：窗口一个接一个往后走。
                let following = life.nextActiveWindow(after: window.upperBound, mood: .active)
                if window.upperBound <= t || length > 1.3 + 1e-6 || length < 0.16 - 1e-6
                    || following.upperBound <= window.upperBound || following.lowerBound < window.lowerBound
                {
                    broken.append(t)
                }
                // 下界以前一点都不动（有窗口在中间开始的话，样子会变）。
                let pose = life.pose(at: t, mood: .active)
                var s = t
                while s < window.lowerBound {
                    if life.pose(at: s, mood: .active) != pose { moved.append(s) }
                    s += 1.0 / 240
                }
            }
            #expect(broken.isEmpty, "\(seed): \(broken.prefix(5))")
            #expect(moved.isEmpty, "\(seed): \(moved.prefix(5))")
        }
    }

    @Test("窗口里连续：每 1/240 秒变化不大；样子只在窗口里变")
    func continuityInsideWindows() {
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            var previous = life.pose(at: base, mood: .active)
            var changes = 0
            var jumps: [TimeInterval] = []
            var outsideWindows: [TimeInterval] = []
            var largest = (lid: 0.0, gaze: 0.0, body: 0.0, smile: 0.0)
            for i in 1...(120 * 240) {
                let t = base + Double(i) / 240
                let pose = life.pose(at: t, mood: .active)
                let lidStep = abs(pose.lid - previous.lid)
                let gazeStep = max(abs(pose.gazeX - previous.gazeX), abs(pose.gazeY - previous.gazeY))
                let bodyStep = max(
                    abs(pose.bodyOffsetY - previous.bodyOffsetY), abs(pose.squashX - previous.squashX),
                    abs(pose.squashY - previous.squashY), abs(pose.tilt - previous.tilt))
                let smileStep = abs(pose.smile - previous.smile)
                largest = (
                    max(largest.lid, lidStep), max(largest.gaze, gazeStep), max(largest.body, bodyStep),
                    max(largest.smile, smileStep)
                )
                if lidStep > 0.13 || gazeStep > 0.17 || bodyStep > 0.03 || smileStep > 0.07 { jumps.append(t) }
                if pose != previous {
                    changes += 1
                    // 前一刻和这一刻之间有一个窗口。
                    if life.nextActiveWindow(after: t - 1.0 / 240, mood: .active).lowerBound > t {
                        outsideWindows.append(t)
                    }
                }
                previous = pose
            }
            #expect(jumps.isEmpty, "\(seed): \(jumps.prefix(5)) largest \(largest)")
            #expect(outsideWindows.isEmpty, "\(seed): \(outsideWindows.prefix(5))")
            #expect(changes > 1_000, "\(seed): \(changes)")
        }
    }

    @Test("不在跑的状态一动不动（在等用户的也是）：样子一直是这种状态的表情，没有动的窗口")
    func staticMoodsNeverMove() {
        #expect(BotinFaceLife.restPose(for: .resting) == BotinFaceLife.restPose)
        #expect(BotinFaceLife.restPose(for: .active) == BotinFaceLife.restPose)
        #expect(BotinFaceLife.restPose(for: .waiting) == Pose(gazeY: -0.35, eyeScale: 1.12))
        #expect(BotinFaceLife.restPose(for: .sleeping) == Pose(lid: 0.12, eyeScale: 1.12))
        #expect(BotinFaceLife.restPose(for: .still) == BotinFaceLife.restPose(for: .sleeping))
        #expect(BotinFaceMood.allCases.filter(\.isAlive) == [.active])
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            for mood in staticMoods {
                let expected = BotinFaceLife.restPose(for: mood)
                var moved: [TimeInterval] = []
                for i in 0..<(60 * 60) {
                    let t = base + Double(i) / 60
                    if life.pose(at: t, mood: mood) != expected { moved.append(t) }
                }
                #expect(moved.isEmpty, "\(seed) \(mood): \(moved.prefix(3))")
                for t in [base, base + 1.5, base + 1_000, -3.0] {
                    #expect(life.nextActiveWindow(after: t, mood: mood) == .infinity ... .infinity, "\(seed) \(mood)")
                }
            }
        }
    }

    @Test("在等用户的不动（用户 2026-11-09：“不运行中的会话不用动”）：每一帧都是睁大眼睛往上看的样子，不眨眼、不转眼、不跳；刚变成在等的也是；没有动的窗口，只有用户点出来的反应")
    func waitingStaysStill() {
        let face = BotinFaceLife.restPose(for: .waiting)
        #expect(face == Pose(gazeY: -0.35, eyeScale: 1.12))
        #expect(!BotinFaceMood.waiting.isAlive)
        let tap = BotinFaceReaction(.tap, start: base + 30)
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            var moved: [TimeInterval] = []
            // 60 秒、每 1/240 秒一帧：以前在等的时候眨眼（4.2 秒一次、0.2 秒）、连跳（3.4 秒一次、0.62 秒），动了一定看得到。
            for i in 0..<(60 * 240) {
                let t = base + Double(i) / 240
                if life.pose(at: t, mood: .waiting) != face { moved.append(t) }
                if life.pose(at: t, mood: .waiting, since: base + 7.3) != face { moved.append(t) }
                if !tap.isPlaying(at: t), life.pose(at: t, mood: .waiting, reactions: [tap]) != face { moved.append(t) }
            }
            #expect(moved.isEmpty, "\(seed): \(moved.prefix(3))")
            for t in [base, base + 1.5, base + 7.3, base + 29] {
                #expect(
                    life.nextActiveWindow(after: t, mood: .waiting, since: base) == .infinity ... .infinity, "\(seed)")
                #expect(life.nextActiveWindow(after: t, mood: .waiting, reactions: [tap]) == tap.window, "\(seed)")
            }
        }
    }

    @Test("小动作的曲线：开头、结尾都正好是原来的样子；跳 0.075、歪 0.14、笑到 1、点头往下")
    func gestureCurves() {
        let bases = [
            BotinFaceLife.restPose, Pose(gazeX: -0.8, gazeY: 0.6, lid: 0.4),
            BotinFaceLife.restPose(for: .waiting), BotinFaceLife.restPose(for: .sleeping),
        ]
        for gesture in BotinFaceGesture.allCases {
            for start in bases {
                #expect(start.adding(gesture, at: 0) == start, "\(gesture)")
                #expect(start.adding(gesture, at: gesture.duration) == start, "\(gesture)")
                #expect(start.adding(gesture, at: -0.1) == start && start.adding(gesture, at: 9) == start)
                let end = start.adding(gesture, at: gesture.duration.nextDown)
                #expect(close(end, start, 1e-6), "\(gesture): \(end)")
                // 半路连续（1/240 秒一步；最快的是点一下时 0.15 秒弯成笑眼）。
                var previous = start
                var u = 0.0
                while u <= gesture.duration {
                    let pose = start.adding(gesture, at: u)
                    #expect(close(pose, previous, 0.07), "\(gesture) \(u)")
                    previous = pose
                    u += 1.0 / 240
                }
            }
        }
        let rest = BotinFaceLife.restPose
        func peak(_ gesture: BotinFaceGesture, _ value: (Pose) -> Double) -> Double {
            stride(from: 0.0, to: gesture.duration, by: 0.001).map { value(rest.adding(gesture, at: $0)) }.max() ?? 0
        }
        // 跳：最高 0.075（在 0.26 秒），蹲下压到 0.90、横着 1.08，起跳拉长到 1.06，空中笑眼 0.6。
        #expect(abs(peak(.hop) { -$0.bodyOffsetY } - 0.075) < 1e-4)
        #expect(abs(rest.adding(.hop, at: 0.26).bodyOffsetY + 0.075) < 1e-9)
        #expect(abs(rest.adding(.hop, at: 0.10).squashY - 0.90) < 1e-9)
        #expect(abs(rest.adding(.hop, at: 0.10).squashX - 1.08) < 1e-9)
        #expect(abs(rest.adding(.hop, at: 0.14).squashY - 1.06) < 1e-9)
        #expect(abs(rest.adding(.hop, at: 0.48).squashY - 0.94) < 1e-9)
        #expect(abs(peak(.hop) { $0.smile } - 0.6) < 1e-9)
        // 点一下：同样跳 0.075，笑到 1。
        #expect(abs(peak(.tap) { -$0.bodyOffsetY } - 0.075) < 1e-4)
        #expect(abs(peak(.tap) { $0.smile } - 1) < 1e-9)
        #expect(rest.adding(.tap, at: 0.7).bodyOffsetY == 0 && rest.adding(.tap, at: 0.7).smile > 0)
        // 歪头：往右是正的、往左是负的，0.14 弧度，眼睛跟着看过去 0.5。
        #expect(abs(rest.adding(.tiltRight, at: 0.6).tilt - 0.14) < 1e-9)
        #expect(abs(rest.adding(.tiltLeft, at: 0.6).tilt + 0.14) < 1e-9)
        #expect(abs(rest.adding(.tiltRight, at: 0.6).gazeX - 0.5) < 1e-9)
        #expect(abs(rest.adding(.tiltLeft, at: 0.6).gazeX + 0.5) < 1e-9)
        // 笑：弯成笑眼，开头身体轻轻往上弹 0.015。
        #expect(rest.adding(.happy, at: 0.5).smile == 1)
        #expect(abs(peak(.happy) { -$0.bodyOffsetY } - 0.015) < 1e-4)
        // 点头：往下点 0.02，眼睛往下看 0.4，两下。
        #expect(abs(peak(.nod) { $0.bodyOffsetY } - 0.02) < 1e-4)
        #expect(abs(rest.adding(.nod, at: 0.18).gazeY - 0.4) < 1e-9)
        #expect(abs(rest.adding(.nod, at: 0.58).gazeY - 0.4) < 1e-9)
        #expect(rest.adding(.nod, at: 0.38).gazeY < 0.01)
    }

    @Test("反应：不管什么状态都做，开头、结尾都是这种状态原来的样子，跳到 0.075；做完了就没有动的窗口")
    func reactions() {
        let life = BotinFaceLife(name: "周报助手")
        // 找一个前后 1.3 秒里没有随机小动作的时刻（在跑的时候也只看反应自己的高度）。
        var start = base + 10.25
        while (-1...1).contains(where: { offset in
            let slot = BotinFaceLife.slot(of: start, length: 6) + Int64(offset)
            guard let gesture = life.gesture(slot: slot) else { return false }
            return gesture.start < start + 1.3 && gesture.start + gesture.kind.duration > start
        }) {
            start += 0.5
        }
        for gesture in [BotinFaceGesture.tap, .happy] {
            let reaction = BotinFaceReaction(gesture, start: start)
            #expect(reaction.end == start + gesture.duration)
            #expect(reaction.window == start...(start + gesture.duration))
            #expect(!reaction.isPlaying(at: start.nextDown) && reaction.isPlaying(at: start))
            #expect(reaction.isPlaying(at: reaction.end.nextDown) && !reaction.isPlaying(at: reaction.end))
            for mood in BotinFaceMood.allCases {
                let plain = life.pose(at: start, mood: mood)
                #expect(life.pose(at: start, mood: mood, reactions: [reaction]) == plain, "\(gesture) \(mood)")
                #expect(
                    life.pose(at: reaction.end, mood: mood, reactions: [reaction])
                        == life.pose(at: reaction.end, mood: mood), "\(gesture) \(mood)")
                var peak = (offset: 0.0, smile: 0.0)
                var t = start
                while t < reaction.end {
                    let pose = life.pose(at: t, mood: mood, reactions: [reaction])
                    peak = (max(peak.offset, -pose.bodyOffsetY), max(peak.smile, pose.smile))
                    t += 1.0 / 240
                }
                #expect(peak.smile > 0.99, "\(gesture) \(mood): \(peak)")
                if gesture == .tap { #expect(abs(peak.offset - 0.075) < 0.002, "\(mood): \(peak)") }
            }
            for mood in staticMoods {
                // 不在跑的只有反应这一个窗口，做完就再也不动了。
                #expect(life.nextActiveWindow(after: start - 5, mood: mood, reactions: [reaction]) == reaction.window)
                #expect(life.nextActiveWindow(after: start + 0.3, mood: mood, reactions: [reaction]) == reaction.window)
                #expect(
                    life.nextActiveWindow(after: reaction.end, mood: mood, reactions: [reaction])
                        == .infinity ... .infinity)
            }
        }
        // 叠在一起（连着点）也夹在范围里。
        let burst = (0..<4).map { BotinFaceReaction(.tap, start: start + Double($0) * 0.05) }
        var t = start
        while t < start + 1.2 {
            let pose = life.pose(at: t, mood: .active, reactions: burst)
            #expect(abs(pose.bodyOffsetY) <= 0.08 && pose.squashY >= 0.88 && pose.squashX <= 1.10, "\(t - start)")
            t += 1.0 / 120
        }
        // 算不准的开始时刻：不做、没有窗口。
        let broken = BotinFaceReaction(.tap, start: .nan)
        #expect(broken.window == nil && !broken.isPlaying(at: base))
        #expect(life.pose(at: base, mood: .resting, reactions: [broken]) == BotinFaceLife.restPose)
        #expect(life.nextActiveWindow(after: base, mood: .resting, reactions: [broken]) == .infinity ... .infinity)
    }

    @Test("反应的列表：做完的去掉，最多留 4 次；还没做完的里最晚结束的时刻")
    func reactionList() {
        let now = base
        let old = BotinFaceReaction(.tap, start: now - 2)
        let playing = BotinFaceReaction(.tap, start: now - 0.5)
        let upcoming = BotinFaceReaction(.happy, start: now + 0.3)
        let list = BotinFaceReaction.adding(upcoming, to: [old, playing], now: now)
        #expect(list == [playing, upcoming])
        #expect(BotinFaceReaction.pendingEnd(list, now: now) == upcoming.end)
        #expect(BotinFaceReaction.pendingEnd(list, now: upcoming.end) == nil)
        #expect(BotinFaceReaction.pendingEnd([old], now: now) == nil)
        #expect(BotinFaceReaction.pendingEnd([], now: now) == nil)
        #expect(BotinFaceReaction.pendingEnd([BotinFaceReaction(.tap, start: .infinity)], now: now) == nil)
        var many: [BotinFaceReaction] = []
        for i in 0..<10 {
            many = BotinFaceReaction.adding(BotinFaceReaction(.tap, start: now + Double(i) * 0.01), to: many, now: now)
        }
        #expect(many.count == 4 && many.last?.start == now + 0.09)
    }

    @Test("状态从哪儿来：在跑的会动，等用户的睁大眼睛往上看（不动），暂停、归档闭着眼，别的不动；和首页那一行一个说法")
    func moodMapping() {
        for state in [RunState.queued, .starting, .running, .waitingChildren, .backoff] {
            #expect(BotinFaceMood(run: state) == .active, "\(state)")
        }
        for state in [RunState.waitingApproval, .waitingDevice, .waitingQuota] {
            #expect(BotinFaceMood(run: state) == .waiting, "\(state)")
        }
        for state in [RunState.succeeded, .failed, .cancelled, .unknown("later")] {
            #expect(BotinFaceMood(run: state) == .resting, "\(state)")
        }
        #expect(BotinFaceMood(instance: .paused) == .sleeping)
        #expect(BotinFaceMood(instance: .archived) == .still && BotinFaceMood(instance: .deleted) == .still)
        for state in [InstanceState.provisioning, .running, .unknown("later")] {
            #expect(BotinFaceMood(instance: state) == .resting, "\(state)")
        }
        // 首页那一行：都在等的按最近在等的那个，有在跑的按最近那个，都没有按实例。
        let running = InstanceActivity(activeRuns: 1, latestRunState: .running, latestRunAt: Date())
        let waiting = InstanceActivity(
            activeRuns: 1, waitingRuns: 1, latestRunState: .waitingApproval, latestWaitingState: .waitingApproval)
        let children = InstanceActivity(
            activeRuns: 1, waitingRuns: 1, latestRunState: .waitingChildren, latestWaitingState: .waitingChildren)
        #expect(BotinFaceMood(state: .running, activity: running) == .active)
        #expect(BotinFaceMood(state: .paused, activity: running) == .active)
        #expect(BotinFaceMood(state: .running, activity: waiting) == .waiting)
        #expect(BotinFaceMood(state: .running, activity: children) == .active)
        // 一个在等审批、另一个没结束（多半是在它后面排队的，用户等的时候又发了一条）：在等的优先，睁大眼睛往上看（首页的行上
        // 不写状态，在等你全靠这张脸）；最近的是哪一个都一样。
        for latest in [RunState.queued, .running, .waitingApproval] {
            let mixed = InstanceActivity(
                activeRuns: 2, waitingRuns: 1, latestRunState: latest, latestWaitingState: .waitingApproval)
            #expect(HomeRowPreview(state: .running, activity: mixed).faceMood == .waiting, "\(latest)")
            #expect(BotinFaceMood(state: .running, activity: mixed) == .waiting, "\(latest)")
            let row = HomeRow(instance: Self.instance(state: .running), activity: mixed)
            #expect(row.faceMood == .waiting, "\(latest)")
        }
        // 两个都在等用户：睁大眼睛，不动。
        let bothWaiting = InstanceActivity(
            activeRuns: 2, waitingRuns: 2, latestRunState: .waitingDevice, latestWaitingState: .waitingDevice)
        #expect(BotinFaceMood(state: .running, activity: bothWaiting) == .waiting)
        #expect(HomeRow(instance: Self.instance(state: .paused), activity: .none).faceMood == .sleeping)
        #expect(HomeRow(instance: Self.instance(state: .running), activity: running).faceMood == .active)
        #expect(BotinFaceMood(state: .running, activity: .none) == .resting)
        #expect(BotinFaceMood(state: .paused, activity: .none) == .sleeping)
        #expect(BotinFaceMood(state: .archived, activity: .none) == .still)
        let message = HomeLastMessage(author: .agent, text: "好了", runID: RunID("r1"), at: Date())
        #expect(HomeRowPreview(state: .paused, activity: .none, lastMessage: message).faceMood == .sleeping)
        #expect(HomeRowPreview(state: .running, activity: running, lastMessage: message).faceMood == .active)
    }

    @Test("刚变成在跑（since）：那一刻和以前正好是不动的样子，之后连续地动，那以前开始的眨眼、转眼、小动作都不算；窗口也从那以后算；过一阵就和一直在跑的一样")
    func activeSince() {
        let rest = BotinFaceLife.restPose
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            var notRest: [TimeInterval] = []
            var jumps: [String] = []
            var early: [TimeInterval] = []
            var moved: [String] = []
            var differs: [TimeInterval] = []
            var started = 0
            // 300 个开始的时刻，错开着落在眨眼、转眼、小动作的槽里各处（不少正赶上在一次眨眼、转眼、小动作的半路）。
            for k in 0..<300 {
                let since = base + Double(k) * 1.373 + 0.0117 * Double(k % 11)
                if life.pose(at: since, mood: .active, since: since) != rest { notRest.append(since) }
                if life.pose(at: since - 0.4, mood: .active, since: since) != rest { notRest.append(since) }
                if life.pose(at: since, mood: .active) != rest { started += 1 }
                // 之后 4 秒每 1/240 秒变化不大（和“窗口里连续”的界限一样）。
                var previous = rest
                for i in 1...(4 * 240) {
                    let t = since + Double(i) / 240
                    let pose = life.pose(at: t, mood: .active, since: since)
                    let lidStep = abs(pose.lid - previous.lid)
                    let gazeStep = max(abs(pose.gazeX - previous.gazeX), abs(pose.gazeY - previous.gazeY))
                    let bodyStep = max(
                        abs(pose.bodyOffsetY - previous.bodyOffsetY), abs(pose.squashX - previous.squashX),
                        abs(pose.squashY - previous.squashY), abs(pose.tilt - previous.tilt))
                    if lidStep > 0.13 || gazeStep > 0.17 || bodyStep > 0.03 || abs(pose.smile - previous.smile) > 0.07 {
                        jumps.append("\(since) +\(Double(i) / 240)")
                    }
                    previous = pose
                }
                // 窗口：第一个在 since 以后开始；一个个往后走，窗口之间样子不变。
                var t = since - 1
                while t < since + 8 {
                    let window = life.nextActiveWindow(after: t, mood: .active, since: since)
                    if window.lowerBound < since || window.upperBound <= t { early.append(since) }
                    let pose = life.pose(at: t, mood: .active, since: since)
                    var s = t
                    while s < window.lowerBound {
                        if life.pose(at: s, mood: .active, since: since) != pose { moved.append("\(since) \(s)") }
                        s += 1.0 / 61
                    }
                    t = window.upperBound
                }
                // 过了两次转眼、一个小动作的槽以后，和一直在跑的一样（同一个 Botin 在列表和标题上又一起动了）。
                for i in 0..<200 {
                    let t = since + 15 + Double(i) * 0.0253
                    if life.pose(at: t, mood: .active, since: since) != life.pose(at: t, mood: .active) {
                        differs.append(t)
                    }
                }
            }
            #expect(notRest.isEmpty, "\(seed): \(notRest.prefix(3))")
            // 不记开始的时刻时，大多数时候第一帧不是不动的样子（这就是要修的那一跳）。
            #expect(started > 100, "\(seed): \(started)")
            #expect(jumps.isEmpty, "\(seed): \(jumps.prefix(3))")
            #expect(early.isEmpty, "\(seed): \(early.prefix(3))")
            #expect(moved.isEmpty, "\(seed): \(moved.prefix(3))")
            #expect(differs.isEmpty, "\(seed): \(differs.prefix(3))")
        }
        // 只对 `active` 有用；NaN 当 -∞；太远的 since（永远不来）一直不动、没有窗口；反应照样做。
        let life = BotinFaceLife(name: "周报助手")
        let tap = BotinFaceReaction(.tap, start: base + 1)
        for i in 0..<500 {
            let t = base + Double(i) * 0.0317
            #expect(life.pose(at: t, mood: .active, since: .nan) == life.pose(at: t, mood: .active))
            for mood in staticMoods {
                #expect(life.pose(at: t, mood: mood, since: t) == BotinFaceLife.restPose(for: mood))
            }
            #expect(life.pose(at: t, mood: .active, since: .infinity) == rest)
            #expect(life.pose(at: t, mood: .active, since: 1e13) == rest)
            #expect(
                life.pose(at: t, mood: .active, since: .infinity, reactions: [tap])
                    == life.pose(at: t, mood: .resting, reactions: [tap]))
        }
        #expect(life.nextActiveWindow(after: base, mood: .active, since: .infinity) == .infinity ... .infinity)
        #expect(life.nextActiveWindow(after: base, mood: .active, since: .infinity, reactions: [tap]) == tap.window)
        #expect(
            life.nextActiveWindow(after: base, mood: .active, since: .nan)
                == life.nextActiveWindow(after: base, mood: .active))
    }

    @Test("一次眨眼：闭眼 0.07 秒、闭着 0.03 秒、睁眼 0.1 秒，两头接得上")
    func blinkCurve() {
        func lid(_ elapsed: TimeInterval) -> Double { BotinFaceLife.blinkLid(at: elapsed, start: 0) }
        #expect(lid(-0.01) == 1)
        #expect(lid(0) == 1)
        #expect(abs(lid(0.035) - (1 - 0.9 * 0.25)) < 1e-12)
        #expect(abs(lid(0.07 - 1e-9) - 0.1) < 1e-6)
        #expect(lid(0.085) == 0.1)
        #expect(abs(lid(0.15) - (0.1 + 0.9 * 0.75)) < 1e-12)
        #expect(abs(lid(0.2 - 1e-9) - 1) < 1e-6)
        #expect(lid(0.2) == 1)
        // 时间的量级在 1e8 秒时，窗口的上界那一刻也正好睁全。
        let start = 815_000_000.123_456_7
        #expect(BotinFaceLife.blinkLid(at: start + 0.2, start: start) == 1)
        #expect(BotinFaceLife.blinkLid(at: (start + 0.2).nextDown, start: start) < 1)
    }

    @Test("奇怪的时间不崩：不是有限数、太远的给这种状态不动的样子和从 t 开始的空窗口；坏的样子夹回范围")
    func nonFinite() {
        let life = BotinFaceLife(name: "周报助手")
        for mood in BotinFaceMood.allCases {
            for t in [TimeInterval.nan, .infinity, -.infinity, 1e300, -1e300, .greatestFiniteMagnitude] {
                #expect(life.pose(at: t, mood: mood) == BotinFaceLife.restPose(for: mood))
            }
            #expect(life.nextActiveWindow(after: .infinity, mood: mood) == .infinity ... .infinity)
            #expect(life.nextActiveWindow(after: -.infinity, mood: mood) == -.infinity ... -.infinity)
            #expect(life.nextActiveWindow(after: .nan, mood: mood) == .infinity ... .infinity)
            #expect(life.nextActiveWindow(after: 1e300, mood: mood) == 1e300...1e300)
        }
        // 范围的两头、2001 年以前、很远的将来都正常。
        for t in [
            -1e12, -1.5, 0, Date.distantPast.timeIntervalSinceReferenceDate,
            Date.distantFuture.timeIntervalSinceReferenceDate, 1e12,
        ] {
            let pose = life.pose(at: t, mood: .active)
            #expect(pose.lid >= 0.1 && pose.lid <= 1 && abs(pose.gazeX) <= 1 && abs(pose.gazeY) <= 1)
            #expect(life.nextActiveWindow(after: t, mood: .active).upperBound > t)
        }
        #expect(BotinFaceLife.restPose == BotinFaceLife.Pose(gazeX: 0, gazeY: 0, lid: 1))
        let bad = Pose(
            gazeX: .nan, gazeY: 7, lid: -1, bodyOffsetY: -1, squashX: .nan, squashY: 3, tilt: -2, eyeScale: .infinity,
            smile: .nan
        ).clamped()
        #expect(
            bad
                == Pose(
                    gazeX: 0, gazeY: 1, lid: 0.1, bodyOffsetY: -0.08, squashX: 1, squashY: 1.10, tilt: -0.15,
                    eyeScale: 1.12, smile: 0))
    }

    /// 首页一行用的实例。
    private static func instance(state: InstanceState) -> Instance {
        Instance(
            id: InstanceID("i1"), agentID: AgentID("a1"), agentVersion: "1", harness: "codex", name: "周报助手",
            state: state, createdAt: Date(timeIntervalSince1970: 0), lastActiveAt: Date(timeIntervalSince1970: 0))
    }

    /// 每一项都差不到 `tolerance`。
    private func close(_ a: Pose, _ b: Pose, _ tolerance: Double) -> Bool {
        let pairs = [
            (a.gazeX, b.gazeX), (a.gazeY, b.gazeY), (a.lid, b.lid), (a.bodyOffsetY, b.bodyOffsetY),
            (a.squashX, b.squashX), (a.squashY, b.squashY), (a.tilt, b.tilt), (a.eyeScale, b.eyeScale),
            (a.smile, b.smile),
        ]
        return pairs.allSatisfy { abs($0.0 - $0.1) <= tolerance }
    }
}
