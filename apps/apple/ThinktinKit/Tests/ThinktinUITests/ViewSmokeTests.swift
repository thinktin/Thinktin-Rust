import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 根页面和每个组件都能实例化、能布局、能渲染（浅色、深色，中文、英文），保证界面层编得过、跑得起来。
/// 快照对比在 12.x 的页面做完后再加。应用框架（抽屉、全局状态页、接入点）的测试在 Shell/AppShellTests.swift。
@MainActor
@Suite("界面冒烟测试")
struct ViewSmokeTests {
    @Test("RootView 用 MockClient 能放进宿主控制器并布局")
    func rootView() {
        let root = RootView(client: MockClient(autoReply: false))
        host(root)
        host(root.environment(\.displayLanguage, .english).preferredColorScheme(.dark))
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

    // MARK: 工具

    private func render(_ view: some View, sourceLocation: SourceLocation = #_sourceLocation) {
        renderInBothAppearances(view, sourceLocation: sourceLocation)
    }

    @discardableResult
    private func host(_ view: some View, sourceLocation: SourceLocation = #_sourceLocation) -> CGSize {
        hostAndLayout(view, sourceLocation: sourceLocation)
    }
}
