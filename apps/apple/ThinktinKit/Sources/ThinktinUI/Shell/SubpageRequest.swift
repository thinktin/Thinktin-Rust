import SwiftUI
import ThinktinKit

extension View {
    /// 有人要打开这一页里的子页 `subpage`（`Router.requestSubpages(_:)`，截图脚本用）时打开它：`isReady`（要用的数据拿到了）
    /// 之后、排在最前面的是它时，等页面的转场走完（`Subpage.settleDelay`）取走并调 `perform`。没有请求时什么也不做。
    func onSubpageRequest(
        _ subpage: Subpage, when isReady: Bool = true, perform: @escaping @MainActor () -> Void
    ) -> some View {
        onSubpageRequest(when: isReady, { $0 == subpage ? () : nil }, perform: { _ in perform() })
    }

    /// 带参数的子页（新建哪种保险箱条目、哪个应用的详情）：`match` 认得的才取走，把它的结果交给 `perform`。
    func onSubpageRequest<Value>(
        when isReady: Bool = true, _ match: @escaping @MainActor (Subpage) -> Value?,
        perform: @escaping @MainActor (Value) -> Void
    ) -> some View {
        modifier(SubpageRequestModifier(isReady: isReady, match: match, perform: perform))
    }
}

private struct SubpageRequestModifier<Value>: ViewModifier {
    let isReady: Bool
    let match: @MainActor (Subpage) -> Value?
    let perform: @MainActor (Value) -> Void

    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        content
            .onAppear(perform: openIfRequested)
            .onChange(of: isReady, openIfRequested)
    }

    private func openIfRequested() {
        guard isReady, let next = router.nextSubpage, match(next) != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: Subpage.settleDelay)
            open()
        }
    }

    /// 还排在最前面（等的时候没被别的页面取走、没被新的请求换掉）才打开。
    private func open() {
        guard let value = router.takeSubpage({ match($0) }) else { return }
        perform(value)
    }
}
