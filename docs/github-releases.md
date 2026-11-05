# 版本发布

源码保存在本仓库，安装包放在 GitHub Releases 的 Assets 中。当前版本为 1.5.0 / build 8。

后续更新时，提交功能或修复、执行相应测试、更新 CHANGELOG、同步版本号与构建号，再创建新的版本标签（例如 v1.5.1）和 Release。保留已经发布的版本和附件。

版本字段位于 `scripts/build-app.sh`、`Sources/ImageAgentDiagnostics/main.swift`、Windows Desktop/Diagnostics 的 csproj、`windows/ImageAgent.Desktop/app.manifest`、`windows/ImageAgent.Core/Diagnostics.cs` 和 `scripts/windows/package-windows.py`。不要替换历史验证记录或参考样例中的旧版本。

macOS 使用 `bash scripts/build-app.sh` 构建，沿用既有签名身份和 bundle ID；Windows 使用 `bash scripts/build-windows.sh` 交叉构建 x64/ARM64 安装版与便携版。各平台包经过检查后再上传为 Release 附件，并提供 SHA256SUMS.txt。

API Key、私有签名文件、数据库、用户图片、构建缓存和助手规划文件不进入仓库或 Release。数据库由程序首次运行自行创建；参考配置只能使用 example.com 与 YOUR_API_KEY 占位符。

当前没有自动构建发布流水线，也没有应用内自动升级；仅创建或推送标签不会自动上传安装包。
