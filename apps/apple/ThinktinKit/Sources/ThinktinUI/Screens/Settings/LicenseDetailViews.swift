import SwiftUI
import ThinktinKit

/// 一个引擎的许可证（开源许可页第一节的一行）：引擎图标（`EngineIcon`，和引擎目录一样的首字圆角方块；引擎不是 Botin，
/// 不画脸）、名字（商标规则下的写法）、出处、右边灰色版本；许可证、许可说明、上游仓库。
/// 许可说明是目录清单里人写的，不是 agent 生成的，不带 AI 生成标识（AgentsText 的说明）。
struct AgentLicenseCard: View {
    let entry: AgentLicenseEntry

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                EngineIcon(name: entry.name, size: EngineIcon.rowSize)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(entry.name)
                        .typography(.headline)
                        .foregroundStyle(Theme.ink)
                    if let byline = entry.byline {
                        Text(byline)
                            .typography(.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Metrics.Spacing.xs)
                Text(verbatim: entry.version)
                    .typography(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
            Label(entry.licenseName, systemImage: entry.isProprietary ? "exclamationmark.shield" : "checkmark.shield")
                .typography(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let spdx = entry.spdx, spdx != entry.licenseName {
                Text(verbatim: spdx)
                    .font(Typography.caption.monospacedFont)
                    .foregroundStyle(Theme.inkTertiary)
            }
            if let note = entry.note {
                Text(note)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = entry.upstreamURL {
                Link(destination: url) {
                    Label(
                        (zh ? "上游仓库：" : "Upstream: ") + (url.host ?? url.absoluteString),
                        systemImage: "arrow.up.right.square"
                    )
                    .typography(.footnote)
                }
                .buttonStyle(.borderless)
                .accessibilityHint(Text(zh ? "在浏览器里打开" : "Opens in your browser"))
            }
        }
        .padding(.vertical, Metrics.Spacing.xxs)
    }
}

/// 一个组件的详情（开源许可页里压进来的子页面）：名字、版本、来源、许可证、作者、原文（点开看）、源码地址。
struct LicenseComponentView: View {
    let component: LicenseComponent
    let directory: URL?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        List {
            Section {
                VStack(spacing: Metrics.Spacing.xxs) {
                    Text(component.name)
                        .font(.title2.bold())
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(component.ecosystemName(language) + " · " + component.version)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.Spacing.s)
                .clearListRow()
            }
            Section {
                LabeledRow(systemImage: "checkmark.shield", title: component.licenseText(language))
            } header: {
                Text(zh ? "许可证" : "License").settingsGroupHeader()
            } footer: {
                if !component.restrictedTerms.isEmpty {
                    Text(
                        (zh ? "原文里有附加条款：" : "The text has additional terms: ")
                            + component.restrictedTerms.joined(separator: zh ? "、" : ", "))
                }
            }
            .themedRow()
            if let authors = component.authors {
                Section {
                    LabeledRow(systemImage: "person.2", title: authors)
                } header: {
                    Text(zh ? "作者" : "Authors").settingsGroupHeader()
                }
                .themedRow()
            }
            Section {
                if component.texts.isEmpty {
                    LabeledRow(systemImage: "doc", title: zh ? "App 里没有带原文" : "No text included in the app")
                }
                ForEach(component.texts) { text in
                    NavigationLink {
                        LicenseTextView(title: text.title(language), path: text.path, directory: directory)
                    } label: {
                        LabeledContent {
                            if let spdx = text.spdx { Text(verbatim: spdx) }
                        } label: {
                            Label(
                                text.title(language),
                                systemImage: text.kind == .standard ? "doc.badge.gearshape" : "doc.text")
                        }
                    }
                }
            } header: {
                Text(zh ? "原文" : "License texts").settingsGroupHeader()
            } footer: {
                if component.texts.contains(where: { $0.kind == .standard }) {
                    Text(
                        zh
                            ? "包里没带原文的，用的是 SPDX 的标准文本，版权方是上面的作者。"
                            : "Where the package doesn't ship its own text, the standard SPDX text is shown; the "
                                + "copyright holders are the authors above.")
                }
            }
            .themedRow()
            if let url = component.sourceURL {
                Section {
                    ExternalLinkRow(title: url.host ?? url.absoluteString, url: url)
                } header: {
                    Text(zh ? "源码" : "Source").settingsGroupHeader()
                } footer: {
                    Text(verbatim: url.absoluteString).settingsGroupFooter()
                }
                .themedRow()
            }
        }
        .insetGroupedList()
        .settingsGroupedList()
        .themedGroupedBackground()
        .settingsNavigationTitle(component.name)
    }
}

/// 一份许可证原文（或整份 `NOTICES.md`）：分段显示（长文滚动时只画看得见的），可以选中、复制全文。
struct LicenseTextView: View {
    let title: String
    @State private var model: LicenseTextModel

    @Environment(\.displayLanguage) private var language
    @State private var copied = false

    init(title: String, path: String, directory: URL?) {
        self.title = title
        _model = State(initialValue: LicenseTextModel(path: path, directory: directory))
    }

    var body: some View {
        let zh = language == .chinese
        content
            .background(Theme.paper)
            .settingsNavigationTitle(title)
            .toolbar {
                ToolbarItem(placement: ToolbarSlot.trailing) {
                    if let text = model.fullText {
                        Button {
                            Pasteboard.copy(text)
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityLabel(Text(copied ? (zh ? "已复制" : "Copied") : (zh ? "复制全文" : "Copy text")))
                    }
                }
            }
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        let zh = language == .chinese
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ContentUnavailableView {
                Label(zh ? "打不开" : "Can't open", systemImage: "doc.questionmark")
            } description: {
                Text(error.message(language))
            }
        case .loaded(let paragraphs):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(verbatim: paragraph)
                            .font(Typography.footnote.monospacedFont)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(Metrics.Spacing.m)
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

#Preview("组件详情 · 浅色中文") {
    LicenseComponentView(component: LicensesPreviewData.component, directory: nil).previewShell()
}

#Preview("组件详情 · 深色英文") {
    LicenseComponentView(component: LicensesPreviewData.component, directory: nil)
        .previewShell(.english, scheme: .dark)
}

#Preview("原文 · 浅色中文") {
    LicenseTextView(title: "LICENSE-MIT", path: "texts/spdx/MIT.txt", directory: CoreLicenses.locate())
        .previewShell()
}

#Preview("原文 · 深色英文、打不开") {
    LicenseTextView(title: "LICENSE", path: "texts/missing", directory: nil)
        .previewShell(.english, scheme: .dark)
}

#Preview("引擎许可证 · 浅色中文") {
    List {
        ForEach(DemoData.agents) { agent in
            AgentLicenseCard(entry: AgentLicenseEntry(agent: agent, language: .chinese))
        }
    }
    .previewShell()
}

#Preview("引擎许可证 · 深色英文") {
    List {
        AgentLicenseCard(entry: AgentLicenseEntry(agent: DemoData.agents[0], language: .english))
    }
    .previewShell(.english, scheme: .dark)
}

/// 预览、界面测试用的组件。
enum LicensesPreviewData {
    static let component = LicenseComponent(
        ecosystem: "cargo", name: "aho-corasick", version: "1.1.5", license: "Unlicense OR MIT",
        authors: "Andrew Gallant <jamslam@gmail.com>",
        sourceURL: URL(string: "https://crates.io/crates/aho-corasick/1.1.5"),
        texts: [
            LicenseText(
                path: "texts/by-hash/0f96a83840e146e4/LICENSE-MIT", name: "LICENSE-MIT", spdx: "MIT", kind: .original),
            LicenseText(
                path: "texts/by-hash/7e12e5df4bae12cb/UNLICENSE", name: "UNLICENSE", spdx: "Unlicense", kind: .original),
            LicenseText(path: "texts/spdx/MIT.txt", name: "MIT", spdx: "MIT", kind: .standard),
        ])
}
