import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// 根页面和每个组件都能实例化、能布局、能渲染（浅色、深色，中文、英文），保证界面层编得过、跑得起来。
/// 快照对比在 12.x 的页面做完后再加。
@MainActor
@Suite("界面冒烟测试")
struct ViewSmokeTests {
    static let size = CGSize(width: 390, height: 844)

    @Test("RootView 用 MockClient 能放进宿主控制器并布局")
    func rootView() {
        let root = RootView(client: MockClient(autoReply: false))
        host(root)
        host(root.environment(\.displayLanguage, .english).preferredColorScheme(.dark))
    }

    @Test("欢迎页的占位文案")
    func welcomeCopy() {
        #expect(WelcomeView.composerPlaceholder(.chinese) == "给 agent 布置一个任务")
        #expect(!WelcomeView.composerPlaceholder(.english).isEmpty)
    }

    @Test("状态点：所有运行状态和实例状态")
    func statusDots() {
        for state in RunState.knownCases + [.unknown("new_state")] {
            render(StatusDot(state))
        }
        for state in InstanceState.knownCases + [.unknown("new_state")] {
            render(StatusDot(state))
        }
        render(StatusDot(StatusAppearance(tone: .success), accessibilityLabel: "在线", size: 12))
    }

    @Test("卡片、胶囊按钮、AI 生成标识、空状态")
    func basicComponents() {
        render(
            Card {
                Text(verbatim: "每周周报")
                AIGeneratedLabel()
            })
        render(Card(background: .bubble, padding: Metrics.Spacing.s, bordered: false) { Text(verbatim: "你好") })
        for kind in [PillButtonKind.primary, .secondary, .destructive] {
            for size in [PillButtonSize.regular, .compact] {
                render(PillButton("重试", systemImage: "arrow.clockwise", kind: kind, size: size) {})
                render(PillButton("重试", kind: kind, size: size) {}.disabled(true))
            }
        }
        render(Button("系统按钮") {}.buttonStyle(.pill(.secondary, size: .compact)))
        render(AIGeneratedLabel())
        render(EmptyStateView(systemImage: "tray", title: "收件箱是空的"))
        render(
            EmptyStateView(systemImage: "square.stack.3d.up", title: "还没有实例", message: "去领养一个", actionTitle: "去领养") {}
        )
    }

    @Test("错误横幅：每一类错误")
    func errorBanners() {
        let errors: [ClientError] = [
            .network(message: "timed out"), .signedOut, .upgradeRequired, .accountFrozen,
            .api(status: 429, code: .rateLimited, message: "", retryAfterSecs: 5),
            .api(status: 409, code: .conflict, message: "", retryAfterSecs: nil),
            .api(status: 422, code: .invalid, message: "", retryAfterSecs: nil),
            .api(status: 404, code: .notFound, message: "", retryAfterSecs: nil),
            .decode(message: "x"), .cache(message: "x"), .containsSecrets(count: 1), .invalidArgument(message: "x"),
            .internal(message: "x"), .malformed(message: "x"), .expired, .badSignature,
            .unsupported(feature: "listDevices"),
        ]
        for error in errors {
            render(ErrorBanner(error, onRetry: {}, onDismiss: {}))
            render(ErrorBanner(error))
        }
        render(ErrorBanner(error: CancellationError()))
    }

    @Test("输入框：空的、有字的、能发和不能发")
    func composer() {
        render(ComposerBar(text: .constant(""), placeholder: "给 agent 布置一个任务"))
        render(ComposerBar(text: .constant("整理周报"), placeholder: "给 agent 布置一个任务") {})
        #expect(!ComposerBar(text: .constant("整理周报"), placeholder: "").canSend)
        #expect(ComposerBar(text: .constant("整理周报"), placeholder: "") {}.canSend)
        #expect(!ComposerBar(text: .constant(" \n "), placeholder: "") {}.canSend)
    }

    @Test("抽屉：打开和关闭")
    func drawer() {
        host(InstanceDrawer(client: MockClient(autoReply: false), isOpen: .constant(true)))
        host(InstanceDrawer(client: MockClient(autoReply: false), isOpen: .constant(false)))
    }

    // MARK: 工具

    /// 浅色中文、深色英文各渲染一次，确认能出图。
    private func render(_ view: some View, sourceLocation: SourceLocation = #_sourceLocation) {
        for (scheme, language) in [(ColorScheme.light, DisplayLanguage.chinese), (.dark, .english)] {
            let content =
                view
                .padding()
                .background(Theme.paper)
                .environment(\.colorScheme, scheme)
                .environment(\.displayLanguage, language)
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: Self.size.width, height: nil)
            #expect(renderer.cgImage != nil, sourceLocation: sourceLocation)
        }
    }

    /// 放进平台的宿主控制器并布局（带导航栈、输入框这类 `ImageRenderer` 画不了的视图用它）。
    private func host(_ view: some View) {
        #if canImport(UIKit)
            let controller = UIHostingController(rootView: view)
            controller.view.frame = CGRect(origin: .zero, size: Self.size)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            #expect(controller.sizeThatFits(in: Self.size).width > 0)
        #elseif canImport(AppKit)
            let controller = NSHostingController(rootView: view)
            controller.view.frame = CGRect(origin: .zero, size: Self.size)
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.sizeThatFits(in: Self.size).width > 0)
        #endif
    }
}
