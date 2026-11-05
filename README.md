# ImageAgent

支持 macOS 和 Windows 的图片创作桌面应用。先由所选文字模型流式整理提示词，再调用用户选择的图片模型生成或编辑图片。

[下载最新版本](https://github.com/Friday770/ImageAgent/releases/latest) · [全部版本](https://github.com/Friday770/ImageAgent/releases) · [更新记录](CHANGELOG.md)

## 下载与安装

当前版本 **1.5.0 / build 8**。在右侧 **Releases** 或上方下载链接中展开 **Assets**，选择对应系统的安装包。

| 系统 | 下载文件 | 安装方法 |
| --- | --- | --- |
| macOS 14+，Apple Silicon | `ImageAgent-1.5.0-macOS-arm64.dmg` 或 `.zip` | 打开 DMG，将 ImageAgent 拖入应用程序；ZIP 完整解压后移动 App |
| Windows 10/11，Intel/AMD x64 | `ImageAgent-1.5.0-windows-x64-Setup.exe` | 双击安装 |
| Windows 10/11，ARM64 | `ImageAgent-1.5.0-windows-arm64-Setup.exe` | 双击安装 |
| Windows 便携版 | 对应架构的 `.zip` | 完整解压后运行 `ImageAgent.exe` |

不需要安装 Codex、Python 或 .NET。首次打开后，在应用中填写自己的 API URL 和 API Key。代码中的 `https://api.example.com/v1` 只是占位地址；`api-config.example.json` 仅作填写格式参考，应用不会从该文件导入凭据。

## 功能

- 流式展示增强后的提示词，可展开、选择和复制。
- 四个图片模型：`gpt-image-2`、`gpt-image-2.5-flare`、`gpt-image-2.5`、`gpt-image-2.5-sunburst`。
- 规划模型默认 `gpt-6.1-sol`，支持模型列表、刷新和手动输入精确模型 ID。
- 支持截图粘贴、参考图、消息复制及已取消请求返回编辑。
- 在当前窗口打开图片，使用细红框或闭合钢笔圈选区域，支持缩放、平移、撤销和局部编辑。
- 保留原图与结果；局部合成保持选区外像素不变，并保留 RGB ICC 配置和透明度。
- 本地会话和短期记忆，默认 24 小时 / 12 轮，可调整或清空记忆。
- 已返回图片优先保存；网络中断、取消或重启后不自动重试或重放计费请求。

接口：文字规划使用 `/v1/responses`，图片生成使用 `/v1/images/generations`，图片编辑使用 `/v1/images/edits`。模型可用性由所连接的服务决定。

## 数据与隐私

发布包不包含 API Key、已保存连接、数据库、聊天、用户图片或开发演示数据。首次运行自动创建空数据库。

| 内容 | 位置 |
| --- | --- |
| macOS 会话与图片 | `~/Library/Application Support/ImageAgent/` |
| Windows 会话与图片 | `%LOCALAPPDATA%\ImageAgent` |
| macOS API Key | 系统钥匙串 |
| Windows API Key | 当前用户的 Windows Credential Manager |

Key 按 API 地址隔离，不写入 SQLite、提示词或日志。示例文件只包含占位符。升级沿用原数据目录；卸载 Windows 应用保留用户数据。

## 开发

- macOS：SwiftUI / AppKit，Swift Package。
- Windows：C# / .NET 10 / Avalonia，独立 Core、Desktop、Diagnostics 与测试项目。

```sh
# macOS 测试与构建；打包需要已有签名身份
bash scripts/test.sh
bash scripts/build-app.sh
```

```powershell
# Windows 测试与自包含构建，需要 .NET SDK 10.0.403
./windows/build.ps1 -Runtime win-x64
```

Windows 安装包的交叉构建：`bash scripts/build-windows.sh`，需要 .NET SDK、Python 3 和 NSIS。

[Windows 使用与开发](windows/README.md) · [验证说明](docs/validation.md) · [版本发布](docs/github-releases.md)

## 当前发布状态

Windows 自动测试已在 Mac 主机通过；Windows 真机的安装、原生剪贴板、输入法、DPI、系统凭据和窗口激活尚未验证。Windows 安装包未做 Authenticode 签名；macOS 包未经 Apple 公证。详细验证范围见验证说明。

软件目前通过 Releases 下载新版更新，没有内置自动检查或安装更新功能。
