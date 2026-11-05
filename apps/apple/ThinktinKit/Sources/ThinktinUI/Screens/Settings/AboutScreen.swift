import SwiftUI
import ThinktinKit

/// 关于（WBS 12.12、12.11，`.about`；入口：设置中心 → 关于 ThinkTin）：品牌、版本号、构建号、App 备案号（16.1 办下来之前显示
/// “办理中”）、用户协议、隐私政策、开源许可，以及 AI 生成内容说明（16.3，docs/compliance.md）。不联网也能看。改版成 insetGrouped
/// `List`（规范 2.5；参考里没有这一页），头部是居中的 `BrandLogo`。
///
/// 页面上的文字都是我们写的，不是 agent 生成的；“AI 生成内容说明”里放一个标识的样子（`AIGeneratedLabel`），告诉用户
/// agent 写的内容旁边会有它。
struct AboutScreen: View {
    var appInfo: AppInfo = .current

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        List {
            Section {
                brand
            }
            .clearListRow()
            Section {
                LabeledContent(zh ? "版本号" : "Version", value: appInfo.version)
                LabeledContent(zh ? "构建号" : "Build", value: appInfo.build)
            }
            .themedRow()
            Section {
                if appInfo.hasICPFiling {
                    Link(destination: AppInfo.icpLookupURL) {
                        SettingsRowLabel(title: zh ? "App 备案号" : "ICP filing", value: appInfo.icpFilingText(language))
                    }
                    .accessibilityHint(Text(zh ? "在浏览器里打开" : "Opens in your browser"))
                } else {
                    LabeledContent(zh ? "App 备案号" : "ICP filing", value: appInfo.icpFilingText(language))
                }
            } footer: {
                Text(
                    appInfo.hasICPFiling
                        ? (zh ? "点开去工信部的网站查询。" : "Opens the MIIT filing lookup.")
                        : (zh ? "App 备案正在办理，办好后显示在这里。" : "The app's ICP filing is in progress and will appear here."))
            }
            .themedRow()
            Section {
                ExternalLinkRow(title: zh ? "用户协议" : "Terms of Service", url: LegalLinks.termsOfService)
                ExternalLinkRow(title: zh ? "隐私政策" : "Privacy Policy", url: LegalLinks.privacyPolicy)
                NavigationLink(value: AppRoute.licenses) {
                    Text(AppRoute.licenses.title(language))
                }
            }
            .themedRow()
            aiContentSection
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .settingsNavigationTitle(AppRoute.about.title(language))
    }

    /// 品牌：Logo、名字、一句话介绍、版本。
    private var brand: some View {
        VStack(spacing: Metrics.Spacing.xs) {
            BrandLogo()
                .frame(height: Metrics.Spacing.xxxl + Metrics.Spacing.m)
                .accessibilityHidden(true)
            Text(verbatim: AppInfo.appName)
                .font(.title.bold())
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(AboutText.tagline(language))
                .font(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            Text(verbatim: appInfo.versionText(language))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.Spacing.s)
        .accessibilityElement(children: .combine)
    }

    /// AI 生成内容说明：几段话，加上标识的样子。
    private var aiContentSection: some View {
        let zh = language == .chinese
        return Section {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                Text(zh ? "Botin 写的内容旁边有这个标识：" : "Content written by Botins carries this label:")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                AIGeneratedLabel()
            }
            ForEach(AboutText.aiContentParagraphs(language), id: \.self) { paragraph in
                Text(paragraph)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
            }
        } header: {
            Text(zh ? "AI 生成内容说明" : "About AI-generated content").textCase(nil)
        }
        .themedRow()
    }
}

#Preview("关于 · 浅色中文") {
    AboutScreen(appInfo: AppInfo(version: "0.1.0", build: "1")).previewShell()
}

#Preview("关于 · 深色英文、有备案号") {
    AboutScreen(appInfo: AppInfo(version: "1.0.0", build: "42", icpFilingNumber: "京ICP备00000000号-1A"))
        .previewShell(.english, scheme: .dark)
}
