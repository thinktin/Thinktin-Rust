import SwiftUI
import ThinktinKit

/// 关于（WBS 12.12、12.11，`.about`；入口：设置中心 → 关于）：品牌、版本号、构建号、App 备案号（16.1 办下来之前显示“办理中”）、
/// 用户协议、隐私政策、开源许可，以及 AI 生成内容说明（16.3，docs/compliance.md）。不联网也能看。
///
/// 页面上的文字都是我们写的，不是 agent 生成的；“AI 生成内容说明”里放一个标识的样子（`AIGeneratedLabel`），告诉用户
/// agent 写的内容旁边会有它。
struct AboutScreen: View {
    var appInfo: AppInfo = .current

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        AccountScrollPage {
            brand
            AccountSection(zh ? "版本" : "Version") {
                AccountRow(systemImage: "number", title: zh ? "版本号" : "Version", value: appInfo.version)
                AccountRowDivider()
                AccountRow(systemImage: "hammer", title: zh ? "构建号" : "Build", value: appInfo.build)
            }
            AccountSection(
                zh ? "备案" : "Filing",
                footer: appInfo.hasICPFiling
                    ? (zh ? "点开去工信部的网站查询。" : "Opens the MIIT filing lookup.")
                    : (zh ? "App 备案正在办理，办好后显示在这里。" : "The app's ICP filing is in progress and will appear here.")
            ) {
                if appInfo.hasICPFiling {
                    Link(destination: AppInfo.icpLookupURL) {
                        AccountRow(
                            systemImage: "checkmark.seal", title: zh ? "App 备案号" : "ICP filing",
                            value: appInfo.icpFilingText(language), showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(zh ? "在浏览器里打开" : "Opens in your browser"))
                } else {
                    AccountRow(
                        systemImage: "checkmark.seal", title: zh ? "App 备案号" : "ICP filing",
                        value: appInfo.icpFilingText(language))
                }
            }
            AccountSection(zh ? "条款" : "Legal") {
                externalLink(
                    AccountLinks.userAgreement, systemImage: "doc.plaintext", title: zh ? "用户协议" : "Terms of Service")
                AccountRowDivider()
                externalLink(
                    AccountLinks.privacyPolicy, systemImage: "hand.raised", title: zh ? "隐私政策" : "Privacy Policy")
                AccountRowDivider()
                NavigationLink(value: AppRoute.licenses) {
                    AccountRow(systemImage: "doc.text", title: AppRoute.licenses.title(language), showsChevron: true)
                }
                .buttonStyle(.plain)
            }
            aiContentSection
        }
        .settingsNavigationTitle(AppRoute.about.title(language))
    }

    /// 品牌：头像（首字母）、衬线的名字、一句话介绍、版本。
    private var brand: some View {
        VStack(spacing: Metrics.Spacing.xs) {
            AccountAvatar(name: AppInfo.appName, size: Metrics.Spacing.xxxl + Metrics.Spacing.m)
            Text(verbatim: AppInfo.appName)
                .typography(.largeTitle)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(AboutText.tagline(language))
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: appInfo.versionText(language))
                .font(Typography.caption.font.monospacedDigit())
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.Spacing.s)
        .accessibilityElement(children: .combine)
    }

    /// AI 生成内容说明：几段话，加上标识的样子。
    private var aiContentSection: some View {
        let zh = language == .chinese
        return AccountSection(zh ? "AI 生成内容说明" : "About AI-generated content") {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                // 上下排：大字号时一行放不下。
                VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                    Text(zh ? "agent 写的内容旁边有这个标识：" : "Content written by agents carries this label:")
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    AIGeneratedLabel()
                }
                ForEach(AboutText.aiContentParagraphs(language), id: \.self) { paragraph in
                    Text(paragraph)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Metrics.Spacing.m)
        }
    }

    private func externalLink(_ url: URL, systemImage: String, title: String) -> some View {
        Link(destination: url) {
            AccountRow(systemImage: systemImage, title: title, showsChevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(language == .chinese ? "在浏览器里打开" : "Opens in your browser"))
    }
}

#Preview("关于 · 浅色中文") {
    AboutScreen(appInfo: AppInfo(version: "0.1.0", build: "1")).previewShell()
}

#Preview("关于 · 深色英文、有备案号") {
    AboutScreen(appInfo: AppInfo(version: "1.0.0", build: "42", icpFilingNumber: "京ICP备00000000号-1A"))
        .previewShell(.english, scheme: .dark)
}
