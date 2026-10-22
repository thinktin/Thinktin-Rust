import SwiftUI
import ThinktinKit

/// “全部停止”这一行（WBS 12.2，4.6）：危险操作，点了先二次确认；做完弹出取消了几个运行、吊销了几个授权、暂停了
/// 几个计划，并刷新抽屉的角标（进行中、待确认）。账号页的“安全”一组用它，12.12 的设置中心也可以直接放。
struct StopAllRow: View {
    let model: StopAllModel

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @State private var confirms = false

    var body: some View {
        let zh = language == .chinese
        VStack(alignment: .leading, spacing: 0) {
            Button {
                confirms = true
            } label: {
                HStack {
                    AccountRow(
                        systemImage: "stop.circle", title: zh ? "全部停止" : "Stop everything",
                        subtitle: zh ? "取消所有运行、吊销运行授权、暂停所有计划" : "Cancel all runs, revoke run grants, pause all plans",
                        tone: .destructive)
                    if model.isStopping {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, Metrics.Spacing.m)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isStopping || app.isOffline)
            if let error = model.error {
                ErrorBanner(
                    error, onRetry: { stop() }, onDismiss: { model.dismissError() }
                )
                .padding([.horizontal, .bottom], Metrics.Spacing.s)
            }
        }
        .confirmationDialog(zh ? "全部停止？" : "Stop everything?", isPresented: $confirms, titleVisibility: .visible) {
            Button(zh ? "全部停止" : "Stop everything", role: .destructive) { stop() }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(StopAllModel.confirmationMessage(language))
        }
        .alert(
            zh ? "已全部停止" : "Everything stopped",
            isPresented: Binding(get: { model.result != nil }, set: { if !$0 { model.result = nil } })
        ) {
            Button(zh ? "好" : "OK", role: .cancel) {}
        } message: {
            Text(model.result?.summary(language) ?? "")
        }
    }

    private func stop() {
        Task {
            if await model.stopAll() != nil {
                // 进行中、待确认的角标跟着变。
                await app.refreshBadges()
            }
        }
    }
}

#Preview("全部停止 · 浅色中文") {
    AccountSection("安全") {
        StopAllRow(model: StopAllModel(client: AccountPreviewClients.signedIn()))
    }
    .padding()
    .previewShell()
}

#Preview("全部停止 · 深色英文、出错") {
    let mock = AccountPreviewClients.signedIn()
    let model = StopAllModel(client: mock)
    AccountSection("Security") {
        StopAllRow(model: model)
    }
    .padding()
    .task {
        mock.failNext(with: .network(message: "offline"))
        await model.stopAll()
    }
    .previewShell(.english, scheme: .dark)
}
