<div align="center">

# Codex 用量小组件

适用于 Windows 和 macOS 的可拖拽用量圆环。悬停即可查看本机观测到的 Codex 用量详情。

[v1.0.0 正式版](https://github.com/libaie/codex-usage-widget/releases/latest) · [v1.1.0 CI 构建](https://github.com/libaie/codex-usage-widget/actions/workflows/ci.yml) · [MIT 许可证](LICENSE) · [English](README.md) · **简体中文**

</div>

> [!IMPORTANT]
> 这是独立个人项目，不是 OpenAI 或 Codex 官方项目，与 OpenAI 无隶属关系，也未获得其背书。它只读取配置的文件系统路径，不调用 Web API，不上传、同步或遥测数据，也不保存账号凭据。显示内容来自本机会话观测，不是官方账单或账户数据。

## 安装

> [!NOTE]
> v1.1.0 源码已进入 `main`。成功的 CI 运行会将 Windows 和 macOS 未签名候选包合并保留 30 天；v1.1.0 签名正式版尚未发布。

### Windows

打开最近一次成功的 [v1.1.0 CI 运行](https://github.com/libaie/codex-usage-widget/actions/workflows/ci.yml)，下载 `unsigned-candidate-v1.1.0-<提交 SHA>`，核对随附的 SHA-256 后运行 `CodexUsageWidget-v1.1.0-windows.exe`。下载 GitHub Actions 构建产物需要登录 GitHub。

也可以下载 `CodexUsageWidget-v1.1.0-windows.zip`。解压后双击 `Start-CodexUsageWidget.vbs`，启动时不会遗留终端窗口；`Start-CodexUsageWidget.cmd` 作为兼容入口保留。

### macOS

从同一个合并候选包中核对 `CodexUsageWidget-v1.1.0-macos-unsigned.zip.sha256`，解压后将 `CodexUsageWidget.app` 移入“应用程序”。这是 Universal 构建，支持 macOS 13 及以上版本的 Apple 芯片和 Intel Mac。

CI 应用尚未签名和公证。首次启动请在访达中右键选择“打开”；如果仍被拦截，可前往“系统设置 → 隐私与安全性 → 仍要打开”。构建、测试和运行未签名版本不需要 Developer ID；只有计划中的签名公证版 `CodexUsageWidget-v1.1.0-macos.dmg` 需要。源码构建方法见[参与开发](CONTRIBUTING.md)。

## 发布文件

| 渠道 | 文件 | 状态 |
|---|---|---|
| Windows CI | `CodexUsageWidget-v1.1.0-windows.exe`、`.exe.sha256`、`.zip` 和 `.zip.sha256` | 包含在合并 CI 候选包中 |
| macOS CI | `CodexUsageWidget-v1.1.0-macos-unsigned.zip` 和 `.zip.sha256` | 包含在合并 CI 候选包中 |
| 计划中的正式版 | 经过 Authenticode 签名的 Windows 文件，以及经过苹果公证的 `CodexUsageWidget-v1.1.0-macos.dmg` 和 `CodexUsageWidget-v1.1.0-macos.dmg.sha256` | 等待签名身份 |

两端统一使用 v1.1.0，因为版本号表示功能集合，不区分操作系统。`v1.1.0` 标签及其源码归档会在签名正式版发布时创建；当前源码位于 `main`。

## 产品截图

### Windows

<p align="center">
  <img src="assets/screenshots/widget-ring.png" alt="Windows Codex 用量百分比圆环" width="112">
  &nbsp;&nbsp;&nbsp;
  <img src="assets/screenshots/widget-details.png" alt="Windows Codex 用量详情卡" width="310">
</p>

### macOS

<p align="center">
  <img src="assets/screenshots/widget-ring-macos.png" alt="macOS Codex 用量百分比圆环" width="112">
  &nbsp;&nbsp;&nbsp;
  <img src="assets/screenshots/widget-details-macos.png" alt="macOS Codex 用量详情卡" width="310">
</p>

<p align="center"><sub>全部截图都由正式界面使用虚构演示数据生成。</sub></p>

## 功能

- 仅显示百分比的置顶圆环，可自由拖拽并在靠近屏幕边缘时吸附。
- 悬停查看最紧限制、重置倒计时、最近 30 分钟活动任务、令牌、上下文占用、输入输出构成、推理占比和单任务缓存数据。
- 单独维护本机累计缓存命中与未命中令牌，不会因切换任务而回落。
- 八种同步主题，以及简体中文（`zh-CN`）、繁体中文（`zh-TW`）、英语（`en-US`）、日语（`ja-JP`）和韩语（`ko-KR`）五种语言。
- 支持键盘访问、单实例保护、低用量提醒和有边界的后台扫描。

## 环境要求

- 带 Windows PowerShell 5.1 和 WPF 的 Windows，或 macOS 13 及以上版本。
- 至少完成一次本机 Codex 任务，使所选 `.codex` 目录中存在 `sessions`。
- 打包后的应用不需要额外第三方运行时。

## 操作

| 操作 | 效果 |
|---|---|
| 拖动圆环 | 移动小组件；靠近屏幕边缘释放时自动吸附。 |
| 悬停约 180 毫秒 | 打开用量详情。 |
| 悬停或聚焦活动任务 | 查看该任务的令牌、缓存和上下文数据。 |
| 右键圆环 | 打开语言、主题、数据目录、提醒和退出菜单。 |
| 圆环聚焦后按回车或空格 | 打开或关闭详情。 |
| Esc | 关闭详情。 |

位置、主题、语言和可选数据目录会在下次启动时恢复。系统语言不受支持或可选语言包缺失时回退到英语。

## 数据定位与存储

两个平台都按以下顺序定位数据目录：

1. 用户之前选择的目录。
2. `CODEX_HOME`。
3. 当前用户的 `.codex` 目录。
4. 以上目录均不含 `sessions` 时，由用户手动选择。

| 用途 | Windows | macOS |
|---|---|---|
| 会话事件和可选任务名称索引 | 定位到的 `.codex` 目录，只读 | 定位到的 `.codex` 目录，只读 |
| 位置、主题、语言和手动数据目录 | `%LOCALAPPDATA%\CodexUsageWidget\preferences.json` | `~/Library/Application Support/CodexUsageWidget/preferences.json` |
| 累计缓存令牌账本 | `%LOCALAPPDATA%\CodexUsageWidget\cache-token-ledger.json` | `~/Library/Application Support/CodexUsageWidget/cache-token-ledger.json` |
| 提醒去重状态 | `%LOCALAPPDATA%\CodexUsageWidget\reminders.json` | `~/Library/Application Support/CodexUsageWidget/reminders.json` |

## 演示模式

演示模式使用仓库内的虚构契约数据，不读取 Codex 数据，也不写入偏好、缓存账本或 `reminders.json`。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexUsageWidget.ps1 -Demo
```

```bash
open CodexUsageWidget.app --args --demo
```

## 统计口径

小组件约每 15 秒读取一次本机会话观测。圆环选择剩余量最少的主额度窗口；同一重置周期取最高已用量，晚到的旧周期观测会被忽略。活动任务只包含最近 30 分钟更新且具有名称的主任务。

缓存命中指 Codex 已复用的缓存输入令牌，缓存未命中指累计输入令牌减去缓存输入令牌。每次刷新只加入各会话新观测到的增量；重复或更低的快照不会让账本下降，也不会重复计数。这里统计的是令牌，不是请求次数。

## 隐私

小组件只读取定位到的文件系统路径，不扫描全盘，不保存账号凭据，也不调用 Web API，不上传、同步或遥测数据。手动选择的目录可以位于网络文件系统，此时会发生操作系统正常的文件读写。

程序只在平台应用数据目录写入 `preferences.json`、`cache-token-ledger.json` 和提醒去重状态 `reminders.json`。主题和语言只影响界面。演示截图不含真实任务、会话、账号或本机路径。

## 开发与发布

- [参与开发与源码构建](CONTRIBUTING.md)
- [架构与信任边界](DESIGN.md)
- [版本记录](CHANGELOG.md)

在 Windows 和 macOS 构建完成签名、且 macOS 构建通过苹果公证前，v1.1.0 不创建公开标签。CI 构建是可测试的未签名候选包，不是正式版。

Windows 内置自检命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexUsageWidget.ps1 -SelfTest
```

## 免责声明

本机会话格式可能变化。界面中的限制、重置时间、任务活动和令牌统计都是尽力观测，不是 OpenAI 官方用量、账单或权益数据。
