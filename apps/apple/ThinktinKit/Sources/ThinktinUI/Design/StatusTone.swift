import Foundation
import ThinktinKit

// 运行状态、实例状态在界面上的样子（docs/ios.md 第 4 节）：状态点的颜色、是否空心、是否在动，以及读屏和列表里
// 显示的状态名。这一层只依赖 Foundation，颜色在 Theme.swift 里由 `StatusTone.color` 给出。
//
// 状态名和安卓端（docs/android-design.md 的状态表）一致。

/// 状态的色调。状态色只用于状态，不用于装饰。
public enum StatusTone: String, CaseIterable, Hashable, Sendable {
    /// 排队、启动中、重试等待：`inkSecondary`。
    case neutral
    /// 运行中：`accent`。
    case active
    /// 等待（审批、电脑、key、子任务）：`warning`。
    case waiting
    /// 成功：`success`。
    case success
    /// 失败：`danger`。
    case failure
    /// 取消、休眠、归档：`inkTertiary`。
    case muted
}

/// 状态点的样子。
public struct StatusAppearance: Hashable, Sendable {
    public var tone: StatusTone
    /// 空心（只有描边）：已归档的实例。
    public var isHollow: Bool
    /// 一圈向外扩散的动画：正在进行（运行中、启动中、创建中）。开了“减弱动态效果”时不动。
    public var pulses: Bool

    public init(tone: StatusTone, isHollow: Bool = false, pulses: Bool = false) {
        self.tone = tone
        self.isHollow = isHollow
        self.pulses = pulses
    }
}

extension RunState {
    /// 状态点的样子：排队 / 启动中 `inkSecondary`，运行中 `accent`，等待类 `warning`，成功 `success`，
    /// 失败 `danger`，取消 `inkTertiary`。
    ///
    /// 退避（崩溃或超时后的重试等待）会自动重试、用户不用处理，和排队同色；不认识的状态也按中性显示。
    public var statusAppearance: StatusAppearance {
        switch self {
        case .queued, .backoff, .unknown: StatusAppearance(tone: .neutral)
        case .starting: StatusAppearance(tone: .neutral, pulses: true)
        case .running: StatusAppearance(tone: .active, pulses: true)
        case .waitingApproval, .waitingDevice, .waitingQuota, .waitingChildren: StatusAppearance(tone: .waiting)
        case .succeeded: StatusAppearance(tone: .success)
        case .failed: StatusAppearance(tone: .failure)
        case .cancelled: StatusAppearance(tone: .muted)
        }
    }

    /// 状态名（列表、读屏）。
    public func localizedName(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .queued: return zh ? "排队中" : "Queued"
        case .starting: return zh ? "启动中" : "Starting"
        case .running: return zh ? "运行中" : "Running"
        case .waitingApproval: return zh ? "等待审批" : "Waiting for approval"
        case .waitingDevice: return zh ? "等待电脑" : "Waiting for computer"
        case .waitingQuota: return zh ? "等待 key" : "Waiting for key"
        case .waitingChildren: return zh ? "等待子任务" : "Waiting for subtasks"
        case .backoff: return zh ? "重试等待" : "Retrying soon"
        case .succeeded: return zh ? "成功" : "Succeeded"
        case .failed: return zh ? "失败" : "Failed"
        case .cancelled: return zh ? "已取消" : "Cancelled"
        case .unknown: return zh ? "未知状态" : "Unknown"
        }
    }
}

extension InstanceState {
    /// 状态点的样子：创建中 `inkSecondary`（在动），运行中 `accent`（在动），休眠 `inkTertiary`，
    /// 已归档 `inkTertiary` 空心，已删除 `inkTertiary`。不认识的状态按中性显示。
    public var statusAppearance: StatusAppearance {
        switch self {
        case .provisioning: StatusAppearance(tone: .neutral, pulses: true)
        case .running: StatusAppearance(tone: .active, pulses: true)
        case .paused, .deleted: StatusAppearance(tone: .muted)
        case .archived: StatusAppearance(tone: .muted, isHollow: true)
        case .unknown: StatusAppearance(tone: .neutral)
        }
    }

    /// 状态名（列表、读屏）。
    public func localizedName(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .provisioning: return zh ? "创建中" : "Creating"
        case .running: return zh ? "运行中" : "Running"
        case .paused: return zh ? "已暂停" : "Paused"
        case .archived: return zh ? "已归档" : "Archived"
        case .deleted: return zh ? "已删除" : "Deleted"
        case .unknown: return zh ? "未知状态" : "Unknown"
        }
    }
}
