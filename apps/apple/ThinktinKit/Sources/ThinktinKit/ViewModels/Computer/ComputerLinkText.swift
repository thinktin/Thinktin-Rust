import Foundation

/// 手机控制电脑（WBS 12.9）的文案。
public enum ComputerLinkText {
    public static func sectionTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "电脑" : "Computers"
    }

    public static func sectionFooter(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "和电脑配对后，agent 在电脑上删除文件、执行命令这类操作要你在手机上签名批准；看文件、打开应用这类普通操作按你给的授权来。签名用这台手机安全芯片里的密钥，每次都要面容 ID。"
            : "Once paired, actions like deleting files or running commands on your computer need your signed approval on this phone; routine actions follow the access you grant. Signing uses a key in this phone's secure chip and needs Face ID every time."
    }

    public static func noComputers(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "还没有电脑登录这个账号。在电脑上装好 ThinkTin 并登录后，这里会出现。"
            : "No computer is signed in to this account. Install ThinkTin on your Mac and sign in, and it shows up here."
    }

    public static func cannotSign(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "这台设备签不了名：要有面容 ID 或触控 ID 并且已经录入。"
            : "This device can't sign: it needs Face ID or Touch ID set up."
    }

    public static func needsRepair(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "录入了新的面容或指纹，签名密钥已经失效。生成新密钥后，要和电脑重新配对。"
            : "A new face or fingerprint was added, so the signing key no longer works. Create a new key, then pair your computers again."
    }

    public static func paired(_ date: Date, now: Date, language: DisplayLanguage) -> String {
        let when = Formatting.relativeTime(date, now: now, language: language)
        return language == .chinese ? "已配对 · \(when)" : "Paired \(when)"
    }

    public static func notPaired(_ language: DisplayLanguage) -> String {
        language == .chinese ? "没有配对" : "Not paired"
    }

    public static func online(_ isOnline: Bool, language: DisplayLanguage) -> String {
        if language == .chinese { return isOnline ? "在线" : "不在线" }
        return isOnline ? "Online" : "Offline"
    }

    public static func waitingForConfirmation(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "已经发给电脑，等电脑确认……电脑要在线、ThinkTin 开着。"
            : "Sent to your computer. Waiting for it to confirm… It needs to be online with ThinkTin open."
    }

    public static func pairInstructions(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "在电脑上打开 ThinkTin，选“配对手机”，扫屏幕上的二维码；扫不了的话，把二维码下面的配对码粘贴到这里。"
            : "On your Mac, open ThinkTin and choose Pair Phone, then scan the QR code. If you can't scan it, paste the pairing code shown under it."
    }

    public static func signReason(_ action: SignAction, computer: String, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch action {
        case .pair: return zh ? "和“\(computer)”配对" : "Pair with “\(computer)”"
        case .approve: return zh ? "批准“\(computer)”上的操作" : "Approve the action on “\(computer)”"
        case .reject: return zh ? "拒绝“\(computer)”上的操作" : "Reject the action on “\(computer)”"
        case .grant: return zh ? "给“\(computer)”授权" : "Grant access to “\(computer)”"
        }
    }

    public enum SignAction: Sendable { case pair, approve, reject, grant }

    public static func duration(_ seconds: TimeInterval, language: DisplayLanguage) -> String {
        let hours = Int(seconds / 3600)
        if language == .chinese {
            return hours >= 24 ? "\(hours / 24) 天" : "\(hours) 小时"
        }
        if hours >= 24 { return hours / 24 == 1 ? "1 day" : "\(hours / 24) days" }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    public static func grantSummary(_ grant: CapabilityGrant, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        var parts: [String] = []
        if !grant.dirs.isEmpty {
            parts.append(
                zh ? "目录：\(grant.dirs.joined(separator: "、"))" : "Folders: \(grant.dirs.joined(separator: ", "))")
        }
        if !grant.apps.isEmpty {
            parts.append(zh ? "应用：\(grant.apps.joined(separator: "、"))" : "Apps: \(grant.apps.joined(separator: ", "))")
        }
        return parts.joined(separator: zh ? "；" : "; ")
    }

    public static func expires(_ date: Date, now: Date, language: DisplayLanguage) -> String {
        let text = Formatting.relativeTime(date, now: now, language: language)
        return language == .chinese ? "\(text)到期" : "Expires \(text)"
    }

    public static func error(_ error: ComputerLinkError, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch error {
        case .client(let error): return error.localizedMessage(language)
        case .pairing(.expired):
            return zh ? "配对码或请求已经过期了，在电脑上重新来一次。" : "The code or request has expired. Start again on your computer."
        case .pairing(.badSignature):
            return zh
                ? "电脑的签名对不上，没有配对。确认扫的是自己电脑上的二维码。"
                : "The computer's signature didn't match, so it wasn't paired. Make sure you scanned the code on your own Mac."
        case .pairing(.malformed):
            return zh ? "不是 ThinkTin 的配对码。" : "That isn't a ThinkTin pairing code."
        case .signer(.cancelled): return zh ? "没有完成验证。" : "Authentication was cancelled."
        case .signer(.unavailable): return cannotSign(language)
        case .signer(.keyInvalidated): return needsRepair(language)
        case .signer(.failed(let detail)): return zh ? "签名失败：\(detail)" : "Signing failed: \(detail)"
        case .notYourComputer:
            return zh
                ? "这台电脑没有登录你的账号（或者已经下线）。先在电脑上用同一个账号登录。"
                : "That computer isn't signed in to your account. Sign in on it with the same account first."
        case .notPaired: return zh ? "这台电脑还没配对。" : "This computer isn't paired yet."
        case .pairingTimedOut:
            return zh
                ? "等了太久电脑还没确认，配对码已经过期。确认电脑在线、ThinkTin 开着，再扫一次。"
                : "The computer didn't confirm before the code expired. Make sure it's online with ThinkTin open, then scan again."
        case .invalidGrant:
            return zh
                ? "至少给一个目录或一个应用。目录要写完整路径（/ 开头，不能有 ..），应用写 bundle id（比如 com.apple.Safari）。"
                : "Add at least one folder or app. Folders need a full path (starting with /, no ..); apps use a bundle ID such as com.apple.Safari."
        }
    }
}
