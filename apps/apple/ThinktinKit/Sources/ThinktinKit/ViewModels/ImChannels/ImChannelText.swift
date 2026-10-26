import Foundation

/// IM 渠道（WBS 12.14）的文案。
public enum ImChannelText {
    public static func vendor(_ vendor: ImVendor, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch vendor {
        case .feishu: return zh ? "飞书" : "Feishu"
        case .lark: return "Lark"
        case .wecom: return zh ? "企业微信" : "WeCom"
        case .dingtalk: return zh ? "钉钉" : "DingTalk"
        case .unknown(let raw): return raw
        }
    }

    public static func event(_ event: ImEvent, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch event {
        case .runFinished: return zh ? "任务完成" : "Task finished"
        case .runFailed: return zh ? "任务失败" : "Task failed"
        case .approval: return zh ? "需要审批" : "Needs approval"
        case .unknown(let raw): return raw
        }
    }

    /// 列表里一行的名字：备注，没有备注时“飞书群机器人 …x7k2”。
    public static func title(_ channel: ImChannel, language: DisplayLanguage) -> String {
        if !channel.label.trimmingCharacters(in: .whitespaces).isEmpty { return channel.label }
        let name = vendor(channel.vendor, language: language)
        return language == .chinese ? "\(name)群机器人 \(channel.hint)" : "\(name) bot \(channel.hint)"
    }

    public static func problem(_ problem: ImChannelProblem, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch problem {
        case .unknownAddress:
            return zh
                ? "不是飞书、Lark、企业微信或钉钉群机器人的 webhook 地址。在群机器人的设置里复制完整的地址，不要改动。"
                : "That isn't a Feishu, Lark, WeCom or DingTalk group bot webhook. Copy the full address from the bot's settings without changing it."
        case .badToken:
            return zh
                ? "地址后面的 token 缺了或者不完整，重新复制一次。"
                : "The token at the end of the address is missing or incomplete. Copy it again."
        case .secretNotSupported:
            return zh ? "企业微信的群机器人没有签名密钥，留空就行。" : "WeCom bots have no signing secret. Leave it empty."
        case .badSecret:
            return zh
                ? "签名密钥是 8 到 128 个字符，钉钉的以 SEC 开头。在机器人的“安全设置 > 加签”里复制。"
                : "The signing secret is 8 to 128 characters (DingTalk secrets start with SEC). Copy it from the bot's security settings."
        case .badLabel:
            return zh ? "备注最多 64 个字。" : "The note can be at most 64 characters."
        case .noEvents:
            return zh ? "至少选一种。不想收消息就把渠道关掉。" : "Pick at least one. To stop messages, turn the channel off."
        }
    }

    /// 最近一次发送失败的原因（服务端记的是英文诊断）：认得出的换成怎么处理，认不出的给原文。
    public static func lastError(_ error: String, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        let text = error.lowercased()
        if text.contains("security check") {
            return zh
                ? "没通过机器人的安全设置（加签、自定义关键词或 IP 白名单）：检查签名密钥，关键词里加上 ThinkTin。"
                : "The bot's security settings rejected it (signing, custom keywords or IP list). Check the secret and add ThinkTin as a keyword."
        }
        if text.contains("custom keyword") {
            return zh
                ? "机器人设了“自定义关键词”，消息里没有：在关键词里加上 ThinkTin。"
                : "The bot uses custom keywords and the message had none. Add ThinkTin as a keyword."
        }
        if text.contains("signature") || text.contains("signing secret") {
            return zh
                ? "签名不对：重新复制机器人的签名密钥，换一次地址。"
                : "The signature was rejected. Copy the bot's signing secret again and update the address."
        }
        if text.contains("ip address") || text.contains("ip list") {
            return zh
                ? "机器人只收白名单里的 IP：在安全设置里关掉 IP 白名单。"
                : "The bot only accepts listed IP addresses. Turn off the IP allowlist."
        }
        if text.contains("invalid") || text.contains("removed") || text.contains("is gone") || text.contains("disabled")
        {
            return zh
                ? "机器人失效了（被删了、换了地址或者群解散了），渠道已经停用：重建机器人后换上新地址，会自动重新打开。"
                : "The bot no longer works (removed, re-created or the group is gone), so the channel was turned off. Add the new address and it turns back on."
        }
        if text.contains("rate limited") || text.contains("throttled") {
            return zh ? "发得太勤被限流了，稍后会自动重发。" : "Rate limited by the platform. It retries automatically."
        }
        if text.contains("does not allow bot") {
            return zh ? "这个群不允许机器人发消息。" : "This group doesn't allow bot messages."
        }
        return zh ? "最近一次没发出去：\(error)" : "The last message wasn't delivered: \(error)"
    }

    /// 新建时的提示：从哪里复制地址、关键词怎么设。
    public static func setupHint(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "在群里添加“自定义机器人”，复制它的 webhook 地址粘贴到这里。机器人设了自定义关键词的话，把 ThinkTin 加进关键词。"
            : "Add a custom bot to the group and paste its webhook address here. If the bot uses custom keywords, add ThinkTin."
    }

    public static func secretHint(_ vendor: ImVendor?, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        if vendor == .wecom { return zh ? "企业微信的机器人没有签名密钥。" : "WeCom bots have no signing secret." }
        return zh ? "机器人开了“加签”就填，没开留空。" : "Fill this in if the bot uses signing; otherwise leave it empty."
    }

    public static func testQueued(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "测试消息排上了，几秒内到群里。没收到就看这里的错误提示。"
            : "Test message queued. It should arrive in a few seconds; if not, check the error shown here."
    }

    public static func testRateLimited(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "测试消息发得太勤了：每小时最多 \(ImChannelRules.testsPerHour) 条，稍后再试。"
            : "Too many test messages: at most \(ImChannelRules.testsPerHour) an hour. Try again later."
    }

    public static func turnOnFirst(_ language: DisplayLanguage) -> String {
        language == .chinese ? "渠道关着，先打开再发测试消息。" : "The channel is off. Turn it on first."
    }

    public static func limitReached(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "最多绑 \(ImChannelRules.maxChannels) 个群，删掉不用的再加。"
            : "You can add up to \(ImChannelRules.maxChannels) groups. Remove one you don't use first."
    }

    public static func emptyTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "还没有绑定群" : "No groups yet"
    }

    public static func emptyMessage(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "绑定飞书、企业微信或钉钉的群机器人，任务完成、失败、需要审批时在群里说一声。"
            : "Connect a Feishu, WeCom or DingTalk group bot to get a message when tasks finish, fail or need approval."
    }

    public static func deleteConfirm(_ language: DisplayLanguage) -> String {
        language == .chinese ? "删除后不再往这个群发消息。" : "No more messages will be sent to this group."
    }

    public static func lastSent(_ date: Date, now: Date, language: DisplayLanguage) -> String {
        let text = Formatting.relativeTime(date, now: now, language: language)
        return language == .chinese ? "上次发送：\(text)" : "Last sent \(text)"
    }
}
