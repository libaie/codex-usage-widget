# TODOS

## 发布

### 为 Windows EXE 增加 Authenticode 签名

**What:** 为公开发布的 Windows 单文件 EXE 增加可信代码签名并验证 SmartScreen 下载体验。

**Why:** SHA-256 能证明文件完整性，但不能替代发布者身份验证；签名可减少用户对未知 EXE 的安全顾虑。

**Context:** v1.1.0 先提供开源引导源码、可复现构建、SHA-256 和现有 ZIP 备用方式，并明确披露 EXE 未签名状态。取得合适的 Windows 代码签名证书或可信签名服务后，在受保护的 GitHub release 环境中签名，确保 PR 和 fork 无法访问凭据。

**Effort:** M
**Priority:** P2
**Depends on:** 代码签名身份验证、证书或可信签名服务

### 提供 Homebrew Cask

**What:** 在公证 DMG 稳定后为 macOS 版本提供 Homebrew Cask 安装与升级入口。

**Why:** 减少重复下载、拖拽安装和版本升级摩擦。

**Context:** 先完成 Developer ID 签名、公证、固定资产命名和公开 v1.1.0 下载闭环。只有确认 DMG URL、SHA 和升级流程稳定后再维护 Cask，避免在发布格式仍变化时同步第二套分发元数据。

**Effort:** S
**Priority:** P3
**Depends on:** 首个已签名并公证的稳定 macOS Release

## Completed
