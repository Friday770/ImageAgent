# 验证说明

## 1.5.0 / build 8

本版本公开源码使用示例 API 地址。所有本地测试均使用临时数据库、合成图像和假 HTTP；没有真实模型调用，也未打包任何已保存的 API 信息或用户数据。

Windows 覆盖 SQLite/Swift 日期兼容、短期记忆、严格 SSE、请求次数、取消与恢复、源会话和编辑 session、真实 Avalonia 控件、画布坐标、导出与凭据边界。图像测试对照 Swift 生成的合成参考样例，涵盖 coverage/ROI、P3/alpha、ICC、EXIF 八种方向和选区外像素保持。

独立自检与诊断验证流式增长、一次规划/一次模拟图片请求、区域 mask/合成、数据重开及已有 Responses 图片恢复。发布流程检查 x64/ARM64 原生 PE、捆绑运行时、图标、许可、ZIP 和 SHA256。

Windows 真机的安装/卸载、原生启动与前台激活、系统凭据、截图剪贴板、中文输入法和多屏 DPI 尚未执行。Mac 的编译、headless 和界面检查不能替代这些平台验证。Windows 包未签名；macOS 包未公证。

在 Windows 上可运行包内 `Verify-Windows.ps1`，或 `ImageAgent.exe --self-test --output <独立临时目录>`；自检只创建合成凭据并清理，不读取已有 API Key，也不访问模型服务。
