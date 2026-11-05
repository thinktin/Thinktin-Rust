import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 改版第 0 轮的底座（docs/ios-ui-redesign.md 2.5–2.10）：Design/Glass.swift 的兼容层，和第 1 轮各页要换上的系统控件
/// （`List`、`Form`、`Section`、`LabeledContent`、`ContentUnavailableView`、左滑、长按预览、搜索、工具栏）。
///
/// 这里的写法就是页面以后的写法：macOS CI 用真实的 SDK 编这个文件，Linux 的 uicheck 用桩编，两边都过才说明桩的签名
/// 和 SDK 对得上。
@MainActor
@Suite("原生控件和玻璃兼容层")
struct NativeControlsTests {
    @Test("玻璃兼容层：按钮样式、玻璃底、挨着的一组玻璃")
    func glassSurfaces() {
        renderInBothAppearances(
            VStack(spacing: Metrics.Spacing.s) {
                Button("主按钮") {}.glassButtonStyle(.prominent)
                Button("次按钮") {}.glassButtonStyle()
                Button("小胶囊") {}
                    .glassButtonStyle(.regular)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                Text(verbatim: "胶囊输入框").padding().glassBackground()
                Text(verbatim: "带引用的输入卡片")
                    .padding()
                    .glassBackground(
                        in: RoundedRectangle(cornerRadius: Metrics.Radius.composerCard, style: .continuous),
                        interactive: true)
                GlassGroup(spacing: Metrics.Spacing.xs) {
                    HStack {
                        Text(verbatim: "全部").padding().glassBackground()
                        Text(verbatim: "媒体").padding().glassBackground()
                    }
                }
            })
    }

    @Test("玻璃兼容层：关闭、确认按钮，工具栏间隔和角标，底部条")
    func glassToolbar() {
        hostAndLayout(
            NavigationStack {
                Text(verbatim: "内容")
                    .floatingBar {
                        Button("新建 Botin") {}
                            .glassButtonStyle(.prominent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                    }
                    .floatingBar(edge: .top, spacing: 0) { Text(verbatim: "顶上的条") }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { CloseButton {} }
                        ToolbarItem(placement: .confirmationAction) { ConfirmButton("保存") {}.disabled(true) }
                        ToolbarItem(placement: .primaryAction) {
                            Button("工作台", systemImage: "square.grid.2x2") {}.toolbarBadge(3)
                        }
                        .toolbarItemBadge(3)
                        GlassToolbarSpacer(.fixed, placement: .primaryAction)
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Section {
                                    Button("复制 ID", systemImage: "doc.on.doc") {}
                                }
                                Button("删除这个 Botin", systemImage: "trash", role: .destructive) {}
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                        }
                        GlassToolbarSpacer(.flexible)
                    }
            })
        for language in [DisplayLanguage.chinese, .english] {
            hostAndLayout(ConfirmButton(isWorking: true) {}.environment(\.displayLanguage, language))
            hostAndLayout(ConfirmButton {}.environment(\.displayLanguage, language))
            hostAndLayout(CloseButton {}.environment(\.displayLanguage, language))
        }
        hostAndLayout(Button("没有角标") {}.toolbarBadge(0))
        hostAndLayout(Button("很多") {}.toolbarBadge(120))
    }

    @Test("关闭、确认按钮：iOS 26 起带系统的角色，旧系统不带")
    func roles() {
        if #available(iOS 26.0, macOS 26.0, *) {
            #expect(GlassRoles.close == .close)
            #expect(GlassRoles.confirm == .confirm)
        } else {
            #expect(GlassRoles.close == nil)
            #expect(GlassRoles.confirm == nil)
        }
    }

    @Test("缩放转场：起点和目标页用同一个命名空间")
    func zoomTransition() {
        hostAndLayout(ZoomTransitionSample())
    }

    #if os(iOS)
        @Test("首页的工具栏：左上不要共用玻璃底，底部条放搜索栏和工作台")
        func homeToolbar() {
            hostAndLayout(
                NavigationStack {
                    List {
                        Text(verbatim: "Botin")
                    }
                    .listStyle(.plain)
                    .searchable(text: .constant(""), isPresented: .constant(false), prompt: "搜索")
                    .toolbarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                            } label: {
                                Text(verbatim: "张")
                                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                                    .glassBackground(in: Circle(), interactive: true)
                            }
                        }
                        .hidesSharedGlassBackground()
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("新建 Botin", systemImage: "plus") {}
                        }
                        ToolbarItem(placement: .bottomBar) {
                            Menu {
                                Button("收件箱", systemImage: "tray") {}
                            } label: {
                                Image(systemName: "square.grid.2x2")
                            }
                            .toolbarBadge(2)
                        }
                        .toolbarItemBadge(2)
                        GlassToolbarSpacer(.fixed, placement: .bottomBar)
                        BottomBarSearchItem()
                    }
                })
        }
    #endif

    @Test("列表：plain 和分组两种版式、带值的行、左滑、长按预览、刷新")
    func lists() {
        let rows = ["周报", "日报"]
        hostAndLayout(
            NavigationStack {
                List {
                    ForEach(rows, id: \.self) { row in
                        NavigationLink(value: row) {
                            Label(row, systemImage: "doc.text")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", systemImage: "trash", role: .destructive) {}
                        }
                        .contextMenu {
                            Button("复制", systemImage: "doc.on.doc") {}
                        } preview: {
                            Text(verbatim: row).padding()
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .refreshable {}
                .sensoryFeedback(.success, trigger: rows.count)
            })
        hostAndLayout(
            NavigationStack {
                List {
                    Section {
                        LabeledContent("默认模型", value: "deepseek-chat")
                        LabeledContent {
                            Text(verbatim: "3 个生效")
                        } label: {
                            Label("计划", systemImage: "clock")
                        }
                        NavigationLink("产出物", value: "artifacts")
                    } header: {
                        Text(verbatim: "Botin")
                    } footer: {
                        Text(verbatim: "脚注")
                    }
                    .themedRow()
                    .textCase(nil)
                    Section("团队", isExpanded: .constant(true)) {
                        Text(verbatim: "周报小组")
                    }
                    .themedRow()
                }
                .themedGroupedBackground()
                .confirmationDialog("删除这个 Botin？", isPresented: .constant(false), titleVisibility: .visible) {
                    Button("删除", role: .destructive) {}
                }
                .alert("改名", isPresented: .constant(false)) {
                    Button("取消", role: .cancel) {}
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("新建", systemImage: "plus") {}
                    }
                }
            })
        #if os(iOS)
            hostAndLayout(
                NavigationStack {
                    List {
                        Section("设置") {
                            Text(verbatim: "账号")
                        }
                        .themedRow()
                    }
                    .listStyle(.insetGrouped)
                    .listSectionSpacing(.compact)
                    .themedGroupedBackground()
                    .toolbar(.hidden, for: .navigationBar)
                })
        #endif
    }

    @Test("表单、选择器、开关、仪表、空状态")
    func formsAndEmptyStates() {
        hostAndLayout(
            NavigationStack {
                Form {
                    Section {
                        TextField("名称", text: .constant("周报助手"))
                    } header: {
                        Text(verbatim: "名称")
                    } footer: {
                        Text(verbatim: "1 到 40 个字")
                    }
                    Section {
                        Picker("外观", selection: .constant(0)) {
                            Text(verbatim: "跟随系统").tag(0)
                            Text(verbatim: "深色").tag(1)
                        }
                        .pickerStyle(.menu)
                        Toggle("触感反馈", isOn: .constant(true))
                        Gauge(value: 0.4) { Text(verbatim: "今日用量") }
                            .gaugeStyle(.linearCapacity)
                    }
                }
                .formStyle(.grouped)
                .themedGroupedBackground()
            })
        hostAndLayout(ContentUnavailableView("还没有 Botin", systemImage: "square.stack.3d.up", description: Text("新建一个")))
        hostAndLayout(
            ContentUnavailableView {
                Label("还没有计划", systemImage: "clock")
            } description: {
                Text(verbatim: "在对话里让它安排，或者手动新建。")
            } actions: {
                Button("新建计划") {}.glassButtonStyle(.prominent)
            })
        hostAndLayout(ContentUnavailableView.search(text: "周报"))
    }
}

/// 缩放转场的起点和终点（`@Namespace` 只能放在视图里）。
private struct ZoomTransitionSample: View {
    @Namespace private var namespace

    var body: some View {
        NavigationStack {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))]) {
                NavigationLink(value: "图片") {
                    Image(systemName: "photo")
                        .zoomTransitionSource(id: "图片", in: namespace)
                }
            }
            .navigationDestination(for: String.self) { id in
                Text(verbatim: id)
                    .zoomNavigationTransition(sourceID: id, in: namespace)
            }
        }
    }
}
