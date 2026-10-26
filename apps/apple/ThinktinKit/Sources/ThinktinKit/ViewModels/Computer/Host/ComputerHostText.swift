import Foundation

/// Mac 菜单栏里“手机控制”（WBS 14.5、14.6、14.8）的文案。
public enum ComputerHostText {
    public static func title(_ language: DisplayLanguage) -> String {
        language == .chinese ? "手机控制" : "Phone control"
    }

    /// 一行状态。
    @MainActor
    public static func status(_ model: ComputerHostModel, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        if let reason = model.stopReason { return stopped(reason, language: language) }
        switch model.connection {
        case .offline:
            return zh ? "已停止：agent 用不了这台电脑。" : "Stopped: agents can't use this Mac."
        case .connecting:
            return zh ? "正在连接……" : "Connecting…"
        case .connected:
            guard model.phone != nil else {
                return zh ? "已连接，还没配对手机。" : "Connected. No phone is paired yet."
            }
            if let tool = model.activeTool {
                return zh
                    ? "agent 正在使用这台电脑：\(toolName(tool, language: language))。点“停止”马上断开。"
                    : "An agent is using this Mac: \(toolName(tool, language: language)). Click Stop to disconnect now."
            }
            return zh
                ? "已连接：agent 可以按手机给的授权使用这台电脑，高危操作要在手机上批准。"
                : "Connected: agents can use this Mac within the access your phone grants; risky actions need your approval on the phone."
        }
    }

    /// 正在执行的工具说成人话（菜单栏的状态行）。
    public static func toolName(_ tool: String, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch tool {
        case "computer_screenshot": return zh ? "截图" : "taking a screenshot"
        case "computer_click": return zh ? "点击" : "clicking"
        case "computer_type": return zh ? "打字" : "typing"
        case "computer_key": return zh ? "按键" : "pressing keys"
        case "computer_open": return zh ? "打开网页或应用" : "opening a page or an app"
        case "computer_list_dir": return zh ? "看文件夹" : "looking at a folder"
        case "computer_read_file": return zh ? "读文件" : "reading a file"
        case "computer_write_file": return zh ? "写文件" : "writing a file"
        case "computer_delete": return zh ? "删除你批准的文件" : "deleting what you approved"
        case "computer_run": return zh ? "执行你批准的命令" : "running the command you approved"
        default: return tool
        }
    }

    public static func stopped(_ reason: HostStopReason, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch reason {
        case .requested:
            return zh ? "已停止。" : "Stopped."
        case .refused:
            return zh
                ? "服务器拒绝了这台电脑：账号可能被冻结了，或者这台电脑已经退出登录。重新登录后再打开。"
                : "The server refused this Mac: the account may be frozen or this Mac was signed out. Sign in again, then turn it on."
        case .replaced:
            return zh
                ? "这台电脑在别处又连了一次（是不是开了两个 ThinkTin？），这里先停下了。"
                : "This Mac connected again from somewhere else (is ThinkTin open twice?), so this one stopped."
        }
    }

    public static func toggle(isEnabled: Bool, language: DisplayLanguage) -> String {
        if language == .chinese { return isEnabled ? "停止" : "开始" }
        return isEnabled ? "Stop" : "Start"
    }

    public static func pairInstructions(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "在手机上打开 ThinkTin，进“设备与账号 → 电脑”，点这台电脑旁边的“配对”，扫这个二维码。"
            : "On your phone, open ThinkTin, go to Devices → Computers, tap Pair next to this Mac and scan this code."
    }

    public static func pairExpired(_ language: DisplayLanguage) -> String {
        language == .chinese ? "二维码过期了，再出一个。" : "The code expired. Make a new one."
    }

    public static func pairingFailed(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "手机的回复验不过（不是这个二维码，或者签名不对），没有配对。再出一个二维码试试。"
            : "The phone's reply couldn't be verified, so it wasn't paired. Make a new code and try again."
    }

    public static func pairButton(hasPhone: Bool, language: DisplayLanguage) -> String {
        if language == .chinese { return hasPhone ? "换一台手机配对" : "配对手机" }
        return hasPhone ? "Pair another phone" : "Pair phone"
    }

    public static func paired(name: String?, language: DisplayLanguage) -> String {
        let phone = name ?? (language == .chinese ? "手机" : "your phone")
        return language == .chinese ? "已和“\(phone)”配对" : "Paired with “\(phone)”"
    }

    public static func noGrants(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "手机还没给授权：看文件、打开应用这类操作都做不了。在手机上给这台电脑授权目录和应用。"
            : "Your phone hasn't granted access yet, so reading files or opening apps won't work. Grant folders and apps from your phone."
    }

    public static func error(_ error: ComputerHostError, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch error {
        case .pairing(let detail): return zh ? "出不了二维码：\(detail)" : "Couldn't make a pairing code: \(detail)"
        case .state(let detail): return zh ? "本地数据读写失败：\(detail)" : "Couldn't read or save local data: \(detail)"
        }
    }
}
