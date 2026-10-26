# 安卓发版与上架（WBS 13.11、13.12）

安卓 App 的三种包、上架各应用商店要准备的材料、官网安装包和应用内更新、签名。App 里的实现见 `apps/android`
（隐私相关在 `ui/privacy/`，更新在 `update/`），进度见 [docs/progress/android-app.md](progress/android-app.md)。

## 1. 三种包

| 渠道（flavor） | 给谁 | 推送 | 更新 | 打包 |
| --- | --- | --- | --- | --- |
| `cn` | 国内应用商店（华为、荣耀、小米、OPPO、vivo、应用宝） | 极光（还没接，见第 5 节） | 商店更新；升级页跳 `market://` | `./gradlew :app:assembleCnRelease` |
| `direct` | 官网下载的安装包 | 同 `cn` | App 里检查、下载、校验、安装（第 3 节） | `./gradlew :app:assembleDirectRelease` |
| `global` | Google Play | FCM（还没接） | Play 更新 | `./gradlew :app:bundleGlobalRelease` |

- 三种包的包名都是 `cn.thinktin.app`，用**同一把签名密钥**（第 4 节）：官网包和商店包能互相覆盖安装，应用内更新也靠签名校验。
- 只有 `direct` 申请 `REQUEST_INSTALL_PACKAGES`、能自己装更新（`BuildConfig.SELF_UPDATE`）：应用商店不允许绕过商店更新，商店包里没有这段功能的入口。
- 每次发版 `versionCode` 加一（`app/build.gradle.kts` 的 `defaultConfig`），三种包同一个版本号。应用内更新按 `versionCode` 比新旧。
- 只打 `arm64-v8a`、`armeabi-v7a`、`x86_64` 三个 ABI（各商店要求带 64 位）；`targetSdk` 35。

## 2. 上架材料（13.11）

### 2.1 App 里已经有的

各商店和工信部的检测会看这些，改动时三处保持一致：App 里的清单（`ui/privacy/PrivacyInfo.kt`）、官网的隐私政策（`https://thinktin.cn/legal/privacy`）、商店后台填的隐私表单。

- **首次启动的隐私政策页**：同意之前不建客户端、不联网、不初始化推送 SDK；能看《隐私政策》《用户协议》和下面的清单；“不同意”先说明为什么用不了，可以再看看，也可以退出（不反复弹窗逼用户同意）。政策有实质改动时把 `PrivacyPolicy.VERSION` 加一，用户下次打开要重新同意。
- **登录页的同意勾选框**：默认不勾，两个链接；没勾就点“获取验证码”先问一句。
- **设置 → 个人信息与权限**：个人信息收集清单（收集什么、用来做什么、什么时候）、第三方共享清单（短信服务商、用户配置的模型厂商、用户绑定的 IM 群机器人）、App 里的第三方 SDK 清单（现在没有）、系统权限（读安装包实际申请的，新依赖带进来的权限也会列出来；要用户允许的显示状态、能去系统设置）、撤回同意（退出登录、回到隐私政策页）。
- **注销账号**：设置 → 注销账号（13.2）。
- **权限按需申请**：通知在登录后才问（13.8），不在启动时问；没有定位、通讯录、相机、存储等权限。
- **AI 生成内容标识**：见 [docs/compliance.md](compliance.md)。

现在安装包申请的权限：

| 权限 | 说明 | 什么时候 |
| --- | --- | --- |
| `INTERNET` | 连接 ThinkTin 的服务 | 安装时 |
| `POST_NOTIFICATIONS` | 审批请求、运行结果等通知 | 登录后问一次（Android 13 起） |
| `USE_BIOMETRIC`、`USE_FINGERPRINT` | 批准审批前确认是本人，只在本机验证 | 安装时（AndroidX Biometric 带进来） |
| `REQUEST_INSTALL_PACKAGES` | 官网包的应用内更新 | 只在 `direct`，装更新时去系统设置打开 |

### 2.2 要人准备的

- **APP 备案**（工信部，上架前必须）：备案号要显示在商店页和 App 里（设置 → 关于；拿到备案号后在设置页加一行，iOS 同样）。
- **软件著作权证书**（或各商店的电子版权认证、免责函）。
- **企业开发者账号**：各商店分别注册（营业执照、法人信息、对公账户验证）。
- **生成式 AI 相关的备案或说明**：App 把用户的任务交给用户自己配置的模型厂商处理，商店审核可能要生成式人工智能服务的备案 / 登记材料，或者调用的模型的备案号。要人和法务确认怎么准备（**要人定**）。
- **审核账号**：审核员要能登录。手机号验证码登录需要服务端支持一个固定验证码的审核账号（现在只有开发环境的 `dev_sms`），并且只在审核期间开（**要人定**，涉及服务端 2.x）。
- **商店素材**：图标、截图（中英文各一套，手机尺寸）、一句话简介、详细介绍、分类（效率 / 工具）、年龄分级、隐私政策和用户协议的网址、客服联系方式。介绍和截图里不出现 Claude、Codex 等第三方商标（docs/licenses.md 第 6 节）。
- **第三方 SDK 披露**：推送 SDK 接上后，在它的渠道的 `FlavorPush.disclosure` 里填上（App 里的 SDK 清单就会列出来），同时改隐私政策、商店的隐私表单。

### 2.3 常见的审核问题（发版前对一遍）

- 首次启动先弹隐私政策、同意前没有任何网络请求（抓包看一遍）；“不同意”后不能直接闪退。
- 隐私政策里列的收集项、SDK、权限和 App 里、安装包里的一致；没有声明的权限不能出现在合并后的清单里（`app/build/intermediates/merged_manifests/cnRelease/.../AndroidManifest.xml`）。
- 登录页的勾选框默认不勾。
- 注销账号、撤回同意都能找到、能用。
- 商店包里没有自更新、没有下载安装其他 App 的入口（`cn` 渠道没有 `REQUEST_INSTALL_PACKAGES`）。

## 3. 官网安装包和应用内更新（13.12）

App（`direct`）每天最多自动检查一次（`Updater.checkIfDue`），设置里能手动“检查更新”，服务端说版本太老（升级页）时进页面就查。流程：拉更新清单 → 有新版本 → 下载到缓存的 `updates/`（边下边算 SHA-256，超过清单里的大小就停）→ 对大小、SHA-256、包名、版本号、签名证书（和装着的 App 一样）→ 交给系统安装（第一次要用户在系统设置里允许 ThinkTin 安装应用）。只认 `https` 的 `thinktin.cn` 和它的子域名。

更新清单是官网上的一个静态文件，默认 `https://thinktin.cn/download/android/latest.json`（打包时 `-PthinktinUpdateUrl=` 能换）：

```json
{
  "version_code": 12,
  "version_name": "0.2.0",
  "apk_url": "https://thinktin.cn/download/android/thinktin-0.2.0.apk",
  "sha256": "64 位十六进制",
  "size": 31457280,
  "min_sdk": 26,
  "notes": {"zh": "更新内容", "en": "What's new"}
}
```

发一版官网包：

1. `./gradlew :app:assembleDirectRelease`（签名的环境变量见第 4 节），产物改名成 `thinktin-<版本>.apk`。
2. `apps/android/scripts/update-manifest.py thinktin-0.2.0.apk --notes-zh "……" --notes-en "……" > latest.json`：读版本号、算 SHA-256 和大小、用 apksigner 确认签了名并打印证书指纹（和上一版对一下）。
3. **先**传安装包，确认能下载、SHA-256 对得上；**再**换 `latest.json`（反过来的话，App 会先看到清单、下载失败）。`latest.json` 的缓存时间设短（几分钟），安装包的文件名带版本号、可以长缓存。旧版本的安装包留着。
4. 官网下载页写上签名证书的 SHA-256 指纹，方便用户自己核对。

回滚：清单只能指向更新的版本（App 不装版本号更小的）。新版本有问题就修了再发一个更大的版本号；还没传 `latest.json` 的话直接不换。强制升级靠服务端的最低版本（返回 426 / UpgradeRequired），官网包的升级页直接在页面上下载安装，商店包跳商店。

## 4. 签名

- 密钥库不进仓库。发版机器上设四个环境变量，`app/build.gradle.kts` 读到才给 release 签名（没设时打出来的 release 包不签名，CI 只检查能打包）：`THINKTIN_KEYSTORE`（密钥库文件路径）、`THINKTIN_KEYSTORE_PASSWORD`、`THINKTIN_KEY_ALIAS`、`THINKTIN_KEY_PASSWORD`。
- 生成一次（RSA 4096，有效期 30 年以上），离线备份两份、两个人各管一份。丢了就不能更新已经装了的 App（只能换包名重新上架）。
- Google Play：用 Play 应用签名时，选“使用现有的应用签名密钥”上传这把密钥，Play 分发的包签名才和官网包、国内商店包一样（**要人定**是否这样做）。
- 华为等商店如果提供“托管签名”，不要用：会换掉签名。

## 5. 还没做的、要人定的

- **推送 SDK 和厂商推送参数**（13.8、13.12）：极光闭源、FCM 带 Play 服务许可，和“只用宽松许可证”的约定冲突，要人定（docs/progress/android-app.md）。定下来后：SDK 依赖只加在 `cn` / `direct`（极光）或 `global`（FCM）；各厂商通道（华为、荣耀、小米、OPPO、vivo）的 AppID / AppKey 用 Gradle 属性或环境变量经 `manifestPlaceholders` 填进清单，不进仓库；官网包不依赖商店，厂商通道照样要在各厂商的推送平台注册。
- 审核账号、APP 备案号的显示、生成式 AI 的材料：见第 2.2 节。
- 发版流水线（`.github/workflows/release.yml`）还不打安卓包：签名密钥放进 CI 的密钥管理之后再加。
