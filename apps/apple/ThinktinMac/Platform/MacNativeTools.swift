import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ThinktinKit

/// 要用 macOS 系统接口的电脑工具（WBS 14.3、14.4）：截图（ScreenCaptureKit）、点击 / 打字 / 按键（`CGEvent`）、打开网页、
/// 应用和文件（`NSWorkspace`）。看目录、读写文件、删除、执行命令由 Rust 的工具服务自己做。
///
/// 手机给的授权（目录、应用）和前台应用在调用之前已经由工具服务核对过；这里再守两条它看不到的：
/// - 点击落在别的应用的窗口上（不是前台应用的）时拒绝：授权是按前台应用给的，点到别处就越权了。
/// - `computer_open` 不打开应用包、可执行文件和脚本这类“打开就会运行”的文件：执行命令是高危操作，要手机每次批准。
///
/// 工具服务在自己的线程上调用。前台应用在主线程上跟着系统通知记下来，最近一张截图的尺寸也记下来（点击按它换算坐标），
/// 都放在加锁的盒子里。
final class MacNativeTools: ComputerNativeTools {
    /// 一次最多打多少字。
    static let maxTypedCharacters = 10_000

    private struct Frontmost: Sendable {
        var bundleID: String?
        var processID: pid_t
    }

    private let frontmost = LockedBox<Frontmost?>(nil)
    private let lastScreenshot = LockedBox<ScreenshotGeometry?>(nil)

    @MainActor
    init() {
        frontmost.set(NSWorkspace.shared.frontmostApplication.map(Self.frontmost))
        // 工具和 App 一样长命，不用留着观察者去注销。
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [frontmost] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            frontmost.set(app.map(Self.frontmost))
        }
    }

    private static func frontmost(_ app: NSRunningApplication) -> Frontmost {
        Frontmost(bundleID: app.bundleIdentifier, processID: app.processIdentifier)
    }

    // MARK: ComputerNativeTools

    func available() -> [String] {
        var tools = ["computer_open"]
        if MacPermissions.hasScreenRecording { tools.append("computer_screenshot") }
        if MacPermissions.hasAccessibility { tools += ["computer_click", "computer_type", "computer_key"] }
        return tools
    }

    func frontmostApp() -> String? { frontmost.get()?.bundleID }

    func call(tool: String, argumentsJSON: String) async -> NativeToolOutput {
        let arguments =
            (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        switch tool {
        case "computer_screenshot":
            return await screenshot()
        case "computer_click":
            guard let x = arguments["x"] as? Int, let y = arguments["y"] as? Int else {
                return .text("x and y are required.", isError: true)
            }
            return click(
                x: x, y: y, right: (arguments["button"] as? String) == "right",
                double: (arguments["double"] as? Bool) ?? false)
        case "computer_type":
            guard let text = arguments["text"] as? String else { return .text("text is required.", isError: true) }
            return await type(text)
        case "computer_key":
            guard let keys = arguments["keys"] as? String else { return .text("keys is required.", isError: true) }
            return key(keys)
        case "computer_open":
            guard let target = arguments["target"] as? String else {
                return .text("target is required.", isError: true)
            }
            return await open(target)
        default:
            return .text("\(tool) is not available on this Mac.", isError: true)
        }
    }

    // MARK: 截图

    private func screenshot() async -> NativeToolOutput {
        guard MacPermissions.hasScreenRecording else {
            return .text(
                "Screen Recording permission is off on this Mac. Ask the user to turn it on from the ThinkTin menu.",
                isError: true)
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
            else { return .text("This Mac has no display to capture.", isError: true) }
            let scale =
                CGDisplayCopyDisplayMode(display.displayID).map {
                    CGFloat($0.pixelWidth) / CGFloat(max($0.width, 1))
                } ?? 1
            let planned = ScreenshotGeometry(displayFrame: display.frame, scale: scale)
            // ThinkTin 自己的窗口（菜单栏面板上可能正显示着配对二维码）不进截图。
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = planned.imageWidth
            configuration.height = planned.imageHeight
            configuration.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            guard
                let data = NSBitmapImageRep(cgImage: image).representation(
                    using: .jpeg, properties: [.compressionFactor: 0.8])
            else { return .text("Cannot encode the screenshot.", isError: true) }
            lastScreenshot.set(
                ScreenshotGeometry(displayFrame: display.frame, imageWidth: image.width, imageHeight: image.height))
            return .image(data, mimeType: "image/jpeg")
        } catch {
            return .text("Cannot take a screenshot: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: 键鼠

    private static let noAccessibility = NativeToolOutput.text(
        "Accessibility permission is off on this Mac. Ask the user to turn it on from the ThinkTin menu.",
        isError: true)

    private func click(x: Int, y: Int, right: Bool, double: Bool) -> NativeToolOutput {
        guard MacPermissions.hasAccessibility else { return Self.noAccessibility }
        guard let geometry = lastScreenshot.get() else {
            return .text(
                "Take a computer_screenshot first: click coordinates are pixels of the latest screenshot.",
                isError: true)
        }
        guard let point = geometry.point(x: x, y: y) else {
            return .text(
                "(\(x), \(y)) is outside the latest screenshot (\(geometry.imageWidth)×\(geometry.imageHeight)).",
                isError: true)
        }
        if let owner = Self.windowOwner(at: point), let front = frontmost.get(), owner != front.processID {
            return .text(
                "That point is on another app's window, not on the app in front (\(front.bundleID ?? "unknown")). "
                    + "Bring the app you want to the front first.",
                isError: true)
        }
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        for click in 1...(double ? 2 : 1) {
            for type in [down, up] {
                let event = CGEvent(
                    mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event?.post(tap: .cghidEventTap)
            }
        }
        return .text("Clicked at (\(x), \(y)).")
    }

    /// 这一点上最前面的普通窗口（第 0 层，不算菜单栏、程序坞）是哪个进程的；没有窗口时是 nil。
    private static func windowOwner(at point: CGPoint) -> pid_t? {
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for window in windows {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.doubleValue, let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                CGRect(x: x, y: y, width: width, height: height).contains(point)
            else { continue }
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        }
        return nil
    }

    private func type(_ text: String) async -> NativeToolOutput {
        guard MacPermissions.hasAccessibility else { return Self.noAccessibility }
        guard text.count <= Self.maxTypedCharacters else {
            return .text("Type at most \(Self.maxTypedCharacters) characters at a time.", isError: true)
        }
        // 换行按回车键打（有的应用不认 Unicode 事件里的换行）；其余的按十几个字符一组发。
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 { Self.press(KeyCombination(keyCode: 0x24)) }
            var chunk: [UniChar] = []
            for character in line {
                chunk += character.utf16
                if chunk.count >= 16 {
                    Self.postUnicode(chunk)
                    chunk = []
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            if !chunk.isEmpty { Self.postUnicode(chunk) }
        }
        return .text("Typed \(text.count) characters.")
    }

    private func key(_ keys: String) -> NativeToolOutput {
        guard MacPermissions.hasAccessibility else { return Self.noAccessibility }
        switch KeyCombination.parse(keys) {
        case .success(let combination):
            Self.press(combination)
            return .text("Pressed \(keys).")
        case .failure(let error):
            return .text(error.description, isError: true)
        }
    }

    private static func postUnicode(_ units: [UniChar]) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
            units.withUnsafeBufferPointer { buffer in
                event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func press(_ combination: KeyCombination) {
        var flags: CGEventFlags = []
        if combination.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combination.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combination.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combination.modifiers.contains(.control) { flags.insert(.maskControl) }
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(combination.keyCode), keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: 打开

    /// 打开就会运行的文件：应用、可执行文件、脚本、安装包、自动操作。
    static let runnableExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "py", "rb", "pl", "php", "js", "jar",
        "terminal", "workflow", "action", "scpt", "scptd", "applescript", "pkg", "mpkg", "dmg", "prefpane",
        "saver", "kext", "plugin", "bundle", "framework", "appex", "xpc", "mobileconfig", "shortcut", "fileloc",
        "inetloc",
    ]

    @MainActor
    private func open(_ target: String) async -> NativeToolOutput {
        // 和工具服务核对授权时的分法一样：网页、绝对路径，其余都当应用的 bundle id。
        if target.hasPrefix("https://") || target.hasPrefix("http://") {
            guard let url = URL(string: target) else { return .text("\(target) is not a valid URL.", isError: true) }
            return NSWorkspace.shared.open(url)
                ? .text("Opened \(target).") : .text("Cannot open \(target).", isError: true)
        }
        if target.hasPrefix("/") {
            let url = URL(fileURLWithPath: target).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .text("\(target) does not exist.", isError: true)
            }
            if Self.isRunnable(url) {
                return .text(
                    "\(target) would run a program when opened. Use computer_run instead; the user approves it on their phone.",
                    isError: true)
            }
            return NSWorkspace.shared.open(url)
                ? .text("Opened \(target).") : .text("Cannot open \(target).", isError: true)
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else {
            return .text("No app with bundle id \(target) is installed on this Mac.", isError: true)
        }
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            return .text("Opened \(target).")
        } catch {
            return .text("Cannot open \(target): \(error.localizedDescription)", isError: true)
        }
    }

    private static func isRunnable(_ url: URL) -> Bool {
        if runnableExtensions.contains(url.pathExtension.lowercased()) { return true }
        let values = try? url.resourceValues(forKeys: [
            .isApplicationKey, .isPackageKey, .isExecutableKey, .isDirectoryKey,
        ])
        if values?.isApplication == true || values?.isPackage == true { return true }
        // 目录在访达里打开；普通文件有执行权限的不开。
        return values?.isDirectory != true && values?.isExecutable == true
    }
}

/// 加锁的值：工具服务的线程和主线程都读写。
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
