import Foundation

// 账号与设备页面（WBS 12.2）上由数据拼出来的文字：全部停止、下线其他设备的结果，设备的平台和状态。中英文都在这里，
// 纯函数，Linux 上测。这些页面没有 agent 写的文字（设备名是 App 报的，结果是数字），按 ios-packages.md 12.5 的
// AI 生成标识规则表都不用标。

extension StopAllResult {
    /// 什么都没停（没有在跑的任务、没有没暂停的计划）。
    public var isEmpty: Bool { runsCancelled == 0 && grantsRevoked == 0 && plansPaused == 0 }

    /// “已取消 3 个运行，吊销 3 个运行授权，暂停 2 个计划。”；什么都没停时说明一下。
    public func summary(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        guard !isEmpty else {
            return zh ? "没有在跑的任务，计划也都已经暂停。" : "Nothing was running, and every plan was already paused."
        }
        if zh {
            return "已取消 \(runsCancelled) 个运行，吊销 \(grantsRevoked) 个运行授权，暂停 \(plansPaused) 个计划。"
        }
        return "Cancelled \(Self.count(runsCancelled, "run")), revoked \(Self.count(grantsRevoked, "run grant")), "
            + "and paused \(Self.count(plansPaused, "plan"))."
    }

    /// 英文的“1 run”“3 runs”。
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

extension SignOutOthersResult {
    /// “已下线 2 台设备。”，顺带全部停止的再接上停了什么。
    public func summary(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        let devices: String
        if devicesSignedOut == 0 {
            devices = zh ? "没有其他登录着的设备。" : "No other devices were signed in."
        } else {
            devices =
                zh
                ? "已下线 \(devicesSignedOut) 台设备，它们要重新登录才能再用。"
                : "Signed out \(StopAllResult.count(devicesSignedOut, "device")). They'll need to sign in again."
        }
        guard let stopped else { return devices }
        return devices + (zh ? "" : " ") + stopped.summary(language)
    }
}

extension DevicePlatform {
    /// 平台名（设备列表的副标题、读屏）。
    public func localizedName(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .ios: return "iOS"
        case .android: return "Android"
        case .macos: return "Mac"
        case .unknown(let raw): return raw.isEmpty ? (zh ? "未知设备" : "Unknown device") : raw
        }
    }
}

extension DeviceInfo {
    /// 设备列表里的名字：App 报上来的设备名；为空时用平台名。iOS 16 起没有权限时设备名只是“iPhone”，
    /// 所以副标题里还有登录时间，方便分清是哪一台（ios-packages.md 12.2）。
    public func displayName(_ language: DisplayLanguage = .current) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? platform.localizedName(language) : trimmed
    }

    /// 状态一行：电脑是“在线” / “离线 · 最近活跃 3 小时前”，手机是“最近活跃 5 分钟前”；本机是“正在使用”。
    public func activityText(now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current)
        -> String
    {
        let zh = language == .chinese
        if isCurrent { return zh ? "正在使用" : "This device" }
        let lastSeen = Formatting.relativeTime(lastSeenAt, now: now, language: language, calendar: calendar)
        if isComputer {
            if isOnline { return zh ? "在线" : "Online" }
            return zh ? "离线 · 最近活跃 \(lastSeen)" : "Offline · last active \(lastSeen)"
        }
        return zh ? "最近活跃 \(lastSeen)" : "Last active \(lastSeen)"
    }

    /// 登录时间：“10月20日登录” / “Signed in Oct 20”。
    public func signedInText(now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current)
        -> String
    {
        let date = Formatting.shortDate(createdAt, now: now, language: language, calendar: calendar)
        return language == .chinese ? "\(date)登录" : "Signed in \(date)"
    }

    /// 读屏的一句话：“张三的 MacBook Pro，Mac，在线，10月2日登录”。
    public func accessibilityText(
        now: Date = Date(), language: DisplayLanguage = .current, calendar: Calendar = .current
    ) -> String {
        [
            displayName(language), platform.localizedName(language),
            activityText(now: now, language: language, calendar: calendar),
            signedInText(now: now, language: language, calendar: calendar),
        ].joined(separator: language == .chinese ? "，" : ", ")
    }
}

/// 注销账号时会删掉什么（docs/compliance.md 第 5 节）：注销页逐条列出来，确认前看清楚。
public enum AccountDeletionNotice {
    /// 会删掉的内容，一条一行。
    public static func deletedItems(_ language: DisplayLanguage = .current) -> [String] {
        if language == .chinese {
            return [
                "全部实例和它们的工作区，正在跑的任务会被停掉",
                "计划、触发器、团队、团队模板和流水线",
                "运行记录、对话内容、产出物和收件箱",
                "模型 key 和密码保险箱（加密密钥一并销毁，无法恢复）",
                "IM 渠道、内容举报和所有登录设备",
            ]
        }
        return [
            "All instances and their workspaces; anything running is stopped",
            "Plans, triggers, teams, team templates and pipelines",
            "Run history, conversations, artifacts and your inbox",
            "Model keys and the password vault (the encryption key is destroyed, so they can't be recovered)",
            "IM channels, content reports and every signed-in device",
        ]
    }

    /// 补充说明：保留什么、之后能不能再注册。
    public static func footnote(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "按法律要求，审计日志和用量记录（只有编号、次数和时间）会继续保留。注销后可以用同一个手机号重新注册，但那是一个新账号，"
                + "原来的内容找不回来。"
            : "As required by law, audit logs and usage records (IDs, counts and times only) are kept. You can sign up "
                + "again with the same phone number later, but it will be a new account and nothing can be restored."
    }
}
