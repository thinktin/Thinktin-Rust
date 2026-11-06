import Foundation
import Testing

@testable import ThinktinKit

// Botin 头像的眨眼、看向（docs/ios-ui-redesign.md 4.4.4）：只由种子和时间决定、范围对、窗口外不动、窗口找得对、
// 窗口里连续、奇怪的时间不崩。

@Suite("Botin 头像的眨眼和看向")
struct BotinFaceLifeTests {
    /// 2026 年 11 月前后的时间（`Date.timeIntervalSinceReferenceDate`），和真机上的量级一样。
    private let base: TimeInterval = 815_000_000
    private let seeds: [UInt64] = [0, 1, 42, 0xDEAD_BEEF, .max, BotinFaceLife(name: "周报助手").seed]

    @Test("同一个种子永远一样；名字的种子是 FNV-1a 64 位，不分大小写、不管首尾空白")
    func deterministic() {
        // 期望值是在别处（Python）按同样的算法独立算出来的，散列改了这里会失败。
        #expect(BotinFaceLife(name: "周报助手").seed == 0x6DFC_DFA8_E38F_1B64)
        #expect(BotinFaceLife(name: "Codex").seed == 0x2FFB_778D_FAE5_4384)
        #expect(BotinFaceLife(name: "").seed == 0xCBF2_9CE4_8422_2325)
        #expect(BotinFaceLife(name: "  CODEX \n") == BotinFaceLife(name: "codex"))
        for seed in seeds {
            let a = BotinFaceLife(seed: seed)
            let b = BotinFaceLife(seed: seed)
            for i in 0..<2_000 {
                let t = base + Double(i) * 0.0731
                #expect(a.pose(at: t) == b.pose(at: t))
                #expect(a.nextActiveWindow(after: t) == b.nextActiveWindow(after: t))
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
            if a.pose(at: t) != b.pose(at: t) { different += 1 }
        }
        #expect(different > 1_000)
        #expect(a.nextActiveWindow(after: base) != b.nextActiveWindow(after: base))
    }

    @Test("600 秒里眨眼的次数说得过去：大约 600 / 4.2 次，加上偶尔连眨的")
    func blinkCount() {
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            var blinks = 0
            var wasOpen = true
            var minimum = 1.0
            for i in 0...(600 * 240) {
                let lid = life.pose(at: base + Double(i) / 240).lid
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

    @Test("范围：眼睛睁开 0.1 到 1，看向 -1 到 1，也真的往四个方向看")
    func ranges() {
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            var extremes = (left: 0.0, right: 0.0, up: 0.0, down: 0.0)
            var outOfRange: [TimeInterval] = []
            for i in 0..<20_000 {
                let t = base + Double(i) * 0.0517
                let pose = life.pose(at: t)
                let inRange =
                    pose.lid >= 0.1 && pose.lid <= 1 && pose.gazeX >= -1 && pose.gazeX <= 1 && pose.gazeY >= -1
                    && pose.gazeY <= 1
                if !inRange { outOfRange.append(t) }
                extremes = (
                    min(extremes.left, pose.gazeX), max(extremes.right, pose.gazeX), min(extremes.up, pose.gazeY),
                    max(extremes.down, pose.gazeY)
                )
            }
            #expect(outOfRange.isEmpty, "\(seed): \(outOfRange.prefix(5))")
            #expect(extremes.left < -0.5 && extremes.right > 0.5, "\(seed)")
            #expect(extremes.up < -0.4 && extremes.down > 0.4, "\(seed)")
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
                let window = life.nextActiveWindow(after: t)
                if t < window.lowerBound {
                    gaps += 1
                    let pose = life.pose(at: t)
                    if pose.lid != 1 { moved.append(t) }
                    var s = t
                    while s < window.lowerBound {
                        if life.pose(at: s) != pose { moved.append(s) }
                        s += 1.0 / 97
                    }
                    if life.pose(at: window.lowerBound.nextDown) != pose { moved.append(window.lowerBound) }
                }
                t = window.upperBound
            }
            #expect(moved.isEmpty, "\(seed): \(moved.prefix(5))")
            #expect(gaps > 50, "\(seed): \(gaps)")
        }
    }

    @Test("下一个窗口：上界在 t 以后，t 和下界之间没有别的窗口（样子一点都没变）")
    func nextWindowInvariants() {
        for seed in seeds {
            let life = BotinFaceLife(seed: seed)
            var broken: [TimeInterval] = []
            var moved: [TimeInterval] = []
            for i in 0..<1_500 {
                let t = base + Double(i) * 0.1373
                let window = life.nextActiveWindow(after: t)
                let length = window.upperBound - window.lowerBound
                // 接着找：窗口一个接一个往后走。
                let following = life.nextActiveWindow(after: window.upperBound)
                if window.upperBound <= t || length > 0.2 + 1e-6 || length < 0.16 - 1e-6
                    || following.upperBound <= window.upperBound || following.lowerBound < window.lowerBound
                {
                    broken.append(t)
                }
                // 下界以前一点都不动（有窗口在中间开始的话，样子会变）。
                let pose = life.pose(at: t)
                var s = t
                while s < window.lowerBound {
                    if life.pose(at: s) != pose { moved.append(s) }
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
            var previous = life.pose(at: base)
            var changes = 0
            var jumps: [TimeInterval] = []
            var outsideWindows: [TimeInterval] = []
            var largest = (lid: 0.0, gaze: 0.0)
            for i in 1...(120 * 240) {
                let t = base + Double(i) / 240
                let pose = life.pose(at: t)
                let lidStep = abs(pose.lid - previous.lid)
                let gazeStep = max(abs(pose.gazeX - previous.gazeX), abs(pose.gazeY - previous.gazeY))
                largest = (max(largest.lid, lidStep), max(largest.gaze, gazeStep))
                if lidStep > 0.13 || gazeStep > 0.17 { jumps.append(t) }
                if pose != previous {
                    changes += 1
                    // 前一刻和这一刻之间有一个窗口。
                    if life.nextActiveWindow(after: t - 1.0 / 240).lowerBound > t { outsideWindows.append(t) }
                }
                previous = pose
            }
            #expect(jumps.isEmpty, "\(seed): \(jumps.prefix(5)) largest \(largest)")
            #expect(outsideWindows.isEmpty, "\(seed): \(outsideWindows.prefix(5))")
            #expect(changes > 1_000, "\(seed): \(changes)")
        }
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

    @Test("奇怪的时间不崩：不是有限数、太远的给不动的样子和从 t 开始的空窗口")
    func nonFinite() {
        let life = BotinFaceLife(name: "周报助手")
        for t in [TimeInterval.nan, .infinity, -.infinity, 1e300, -1e300, .greatestFiniteMagnitude] {
            #expect(life.pose(at: t) == BotinFaceLife.restPose)
        }
        #expect(life.nextActiveWindow(after: .infinity) == .infinity ... .infinity)
        #expect(life.nextActiveWindow(after: -.infinity) == -.infinity ... -.infinity)
        #expect(life.nextActiveWindow(after: .nan) == .infinity ... .infinity)
        #expect(life.nextActiveWindow(after: 1e300) == 1e300...1e300)
        // 范围的两头、2001 年以前、很远的将来都正常。
        for t in [
            -1e12, -1.5, 0, Date.distantPast.timeIntervalSinceReferenceDate,
            Date.distantFuture.timeIntervalSinceReferenceDate, 1e12,
        ] {
            let pose = life.pose(at: t)
            #expect(pose.lid >= 0.1 && pose.lid <= 1 && abs(pose.gazeX) <= 1 && abs(pose.gazeY) <= 1)
            #expect(life.nextActiveWindow(after: t).upperBound > t)
        }
        #expect(BotinFaceLife.restPose == BotinFaceLife.Pose(gazeX: 0, gazeY: 0, lid: 1))
    }
}
