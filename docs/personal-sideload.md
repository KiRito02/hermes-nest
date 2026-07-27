# Personal sideload / 个人侧载

Hermes Nest is distributed as one unsigned iOS App. It has no Share
Extension, widget, Live Activity, App Group, TestFlight, or App Store
requirement. GitHub Actions builds the device binary on macOS; AltStore or
SideStore supplies the owner's free Apple Account signature on Windows.

Hermes Nest 以单一未签名 iOS App 的形式分发，不需要分享扩展、桌面小组件、实时活动、
App Group、TestFlight 或 App Store。GitHub Actions 在 macOS 上构建真机二进制，
Windows 上再由 AltStore 或 SideStore 使用用户自己的免费 Apple 账户签名。

## English

### Build the artifact

1. Open the repository's **Actions** tab.
2. Select **Personal Sideload Artifact**.
3. Choose the approved branch or commit and run the workflow.
4. Download `HermesNest-unsigned-<commit>`.
5. Extract the artifact zip once. The file to install is
   `HermesNest-unsigned.ipa`; do not extract the IPA itself.

The workflow runs the release-readiness tests, builds a Release device App
without an owner identity, rejects nested extensions, and packages exactly
`Payload/HermesNest.app`.

### Install from Windows

Use the current official instructions for either AltStore or SideStore. Select
`HermesNest-unsigned.ipa` when the tool asks for an IPA. The signing tool
re-signs the App with your Apple Account before installing it; the repository
and artifact contain neither your password nor your Team ID.

A free Apple Account normally requires periodic re-signing. Background refresh
depends on the selected sideload tool and network setup. Treat those limits as
properties of the personal-signing workflow, not of Hermes Nest or Companion.

After installation, open Hermes Nest and enter only:

- the HTTPS URL that exposes Companion; and
- a one-time secret from `Companion/companionctl pair`.

Never enter the Hermes Gateway `API_SERVER_KEY` in the App.

### Optional local Xcode signing

On a Mac, copy `Config/Local.xcconfig.example` to the gitignored
`Config/Local.xcconfig`, set `DEVELOPMENT_TEAM`, and build the `HermesMobile`
scheme. The default bundle ID is `com.kirito02.hermesnest`. A personal override
may be used locally when the signing portal requires a unique ID.

## 简体中文

### 构建侧载包

1. 打开仓库的 **Actions** 页面。
2. 选择 **Personal Sideload Artifact**。
3. 选择已经批准的分支或提交并运行工作流。
4. 下载 `HermesNest-unsigned-<commit>`。
5. 将下载的 artifact zip 解压一次。要安装的文件是
   `HermesNest-unsigned.ipa`，不需要再解压 IPA。

工作流会先运行发布边界检查，再构建不包含个人开发者身份的 Release 真机 App，
拒绝任何内嵌扩展，最后只打包 `Payload/HermesNest.app`。

### 在 Windows 上安装

按照 AltStore 或 SideStore 当前的官方说明操作；工具要求选择 IPA 时，选择
`HermesNest-unsigned.ipa`。侧载工具会用你的 Apple 账户重新签名后再安装。
仓库和未签名 artifact 都不会包含你的密码或 Team ID。

免费 Apple 账户通常需要定期重新签名。后台刷新是否可用取决于所选侧载工具及
网络环境，这属于个人签名流程的限制，并不是 Hermes Nest 或 Companion 的限制。

安装后打开 Hermes Nest，只需要输入：

- 对外提供 Companion 的 HTTPS 地址；
- 运行 `Companion/companionctl pair` 生成的一次性配对密钥。

不要在 App 中输入 Hermes Gateway 的 `API_SERVER_KEY`。

### 可选：在 Mac 上本地签名

把 `Config/Local.xcconfig.example` 复制为已被 git 忽略的
`Config/Local.xcconfig`，填写 `DEVELOPMENT_TEAM`，然后构建
`HermesMobile` scheme。默认 Bundle ID 为 `com.kirito02.hermesnest`；
如果 Apple 签名后台要求唯一标识，可以只在本地覆盖它。

## Physical-device acceptance / 真机验收

After the first install, verify connection, pairing, one text run, one image
attachment, stop, approval, files, and built-in Memory on both the intended
iPhone and iPad. Simulator CI cannot validate Apple Account provisioning,
AltStore/SideStore refresh, the reverse proxy, or the physical network path.

首次安装后，请在计划使用的 iPhone 和 iPad 上分别验证：连接、配对、一轮文字
对话、一张图片附件、停止、审批、文件和内置 Memory。模拟器 CI 无法验证
Apple 账户 provisioning、AltStore/SideStore 刷新、反向代理或真实网络链路。
