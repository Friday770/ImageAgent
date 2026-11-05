# ImageAgent Windows

这是与 macOS 1.5.0/build 8 对齐的独立 Windows 桌面实现。运行正式发布包里的 `ImageAgent.exe`，无需安装 .NET、Python、Codex 或浏览器。支持 Windows 10/11 x64 与 ARM64；便携包与当前用户安装程序由仓库发布脚本生成。

## 使用

1. 填写 API 地址与此地址的 Key，验证并连接。正常 Windows 模式只把 Key 保存进 Windows Credential Manager，按规范化 endpoint 隔离，SQLite/日志/导出均不写 Key。
2. 输入需求，Enter 换行，Ctrl+Enter 发送。Ctrl+V 可以粘贴截图或单张图片文件；原文字保留，已有附件不会被替换。支持 PNG、TIFF、JPEG、WebP，并将单帧 BMP/GIF 等可解码剪贴板图像正规化为 PNG。
3. 图片卡片的“查看与编辑”在当前窗口打开深色工作区。标注使用闭合钢笔；也可切换方框、平移。红线只是可视化边界，内部保持原图；可撤销或清空。擦除只追加一次预设要求，仍需明确提交。
4. 工作区支持 fit、100%、±、滚轮平移、Ctrl/Alt+滚轮缩放、捏合、空格拖动以及 Esc 关闭。接受并持久记录任务后返回来源聊天；关闭不会取消任务，也不会自动打开结果。
5. 用户消息可精确复制。仅准确关联且已取消的任务可“返回编辑”；这不会重发或移除历史，且不会覆盖其他草稿、附件或选区。
6. 设置中的规划模型允许列表选择、刷新或手工填写；四种图片模型单独选择。修改 API 地址会清空并隐藏 Key 草稿；取消/关闭清除临时凭据。验证、凭据保存及 SQLite 保存全部成功后才切换连接。

Windows 正常模式在创建数据库前取得当前用户的生产实例互斥锁；重复启动只向现有窗口发送当前用户专用的激活请求并退出，避免第二个进程把仍在运行的任务标为中断。锁由操作系统在进程崩溃后释放，下一次启动再执行恢复；离线演示和自检彼此独立。

数据在 `%LOCALAPPDATA%\ImageAgent`。图片保存在 `assets/<conversationID>/`，已返回结果的恢复字节在 `recovery/<runID>/`。设置可以打开数据目录；编辑失败可打开恢复文件。卸载应用应保留用户数据。复制来的 Mac 数据目录采用相同五表 SQLite schema 与 Swift JSON payload；凭据不跨平台迁移，需要在 Windows 重新输入。

## 构建与测试

依赖锁定 .NET SDK 10.0.403 / net10.0、Avalonia 12.1.5、Microsoft.Data.Sqlite 10.0.14、SkiaSharp 3.119.4；TIFF 使用 BitMiracle.LibTiff.NET 2.4.660。`packages.lock.json` 记录直接及传递版本，第三方许可在 `licenses/`，随 publish 复制。

```powershell
./windows/build.ps1
./windows/build.ps1 -Runtime win-x64 -OutputDirectory ./dist/windows/win-x64
./windows/build.ps1 -Runtime win-arm64 -OutputDirectory ./dist/windows/win-arm64
```

在仓库 Mac 主机上的等价命令：

```sh
dotnet test windows/ImageAgent.sln -c Release
dotnet build windows/ImageAgent.Desktop -c Release
```

测试使用 xUnit v3 与 Avalonia.Headless.XUnit 12.1.5，全部采用显式随机临时根、真实 SQLite/文件/图像编解码、假 HTTP 和假凭据。真实控件级用例覆盖文本粘贴/逐次撤销、图片附件、覆盖层隐藏背景、1×/2× render scaling 下实际 MouseDown/Move/Up 方框与闭合钢笔，以及 200% 缩放和实际平移后原图坐标、流式文字选择保持、设置已存 Key 的初次遮蔽加载/改地址清除/取消/保存/重开、未过滤的规划模型下拉、busy 禁用和 Ctrl+, 设置快捷键。独立合成 named mutex 用例验证竞争、释放和重新获取；生产策略用例确认第二实例不会构造 store。几何/coverage/ROI/合成期望值直接读取开发验证以原 Swift Core 生成的 `ParityFixtures/manifest.json`；`orientation-manifest.json` 验证八种 EXIF 方向。另存副本回归直接经过真实 Export 路径，验证选择原文件仍保留原字节、本地副本精确一致；忙碌任务结束后原工作区的提交按钮自动恢复；包含配置 Key 的原始/编码地址在请求与保存前拒绝。测试覆盖严格流式身份/终态、请求计数、JSON Date 2001 epoch、字素簇预算、外部像素/ICC、取消后的字节保存、原始 native 图片先于全部元数据落盘、重启恢复、跨来源草稿与 session 保护、连接失败补偿。Windows-only 的系统凭据测试只使用一次性的合成 target，非 Windows 显式 skip。

## 命令行诊断

发布包同时包含 `ImageAgentDiagnostics.exe`。它始终使用独立的 `--output` 目录，直接复用同一 Core，不读取正常应用的 SQLite 或 OS 凭据。报告为 `report.json`，图片路径会打印到控制台。

```powershell
./ImageAgentDiagnostics.exe --local --output "$env:TEMP\ImageAgentLocalQA"
./ImageAgentDiagnostics.exe --streaming --output "$env:TEMP\ImageAgentStreamQA"
./ImageAgentDiagnostics.exe --region --output "$env:TEMP\ImageAgentRegionQA"
./ImageAgentDiagnostics.exe --region --reference C:\Pictures\sample.png --region-rect 5,7,20,15 --output "$env:TEMP\ImageAgentRegionFileQA"
./ImageAgentDiagnostics.exe --recover-response C:\Diagnostics\response.json --output "$env:TEMP\ImageAgentRecovered"
./ImageAgentDiagnostics.exe --help
```

无模式参数也执行 local。`--streaming` 同时检查成功的真实增量 SSE 与中断后未完成提示词的终态门禁；`--region` 验证实际 Core multipart 的原始 crop/mask、源 ID、向内合成与逐像素外部保留。`--recover-response` 只读取已有 Responses JSON 的有效 native 图片，标记模型未验证，先保存全部已知原始字节；再次执行保留已有结果，不发 HTTP 请求。

`--live-generate`、`--live-edit`、`--live-region` 是显式真实请求入口，需要调用进程提供 `OPENAI_BASE_URL` 和 `OPENAI_API_KEY`；仅这些模式消费并清除这两个进程变量。可指定 `--model`、`--size`、`--quality`、`--prompt`、`--edit-prompt`、`--reference` 和 `--region-rect`；模型/尺寸/质量必须精确有效，诊断质量默认 low，局部尺寸固定 auto。live-region 必须有原始 reference，不生成底图。已成功结果直接保留，尝试失败/中断的输出目录不会重新规划或重放。两个 live 标志 generate/edit 同时显式提供时，各执行一次对应的独立任务。

开发验证中，这些 live 路由只通过注入的假 HTTP/假环境变量测试，未使用真实服务或真实 Key。真实离线 CLI local/streaming/region/recover-response 已在 Mac 主机实际执行；Windows console/原生窗口行为仍需 Windows 实机记录。

## 离线自检与预览

```powershell
./ImageAgent.exe --self-test --output "$env:TEMP\ImageAgentSelfTest"
```

`self-test.json` 包含真实增量预览次数、规划/图片调用次数、选区外逐像素检查、ICC、数据重开、离线 Responses native 恢复及平台状态。退出码 0 表示已执行的检查通过。此路径不读取正常用户凭据，不访问网络；Windows 上只验证一个唯一合成 Credential Manager target 并在 finally 中删除。

非 Windows 的正常模式在创建任何 store 前拒绝；主机 UI 验证必须显式命名隔离 session：

```sh
dotnet ImageAgent.dll --frontend-demo --frontend-demo-session qa_20261104
```

也支持 `--connection-demo`、`--streaming-demo`、`--demo` 及对应 `--...-demo-session` / `--demo-session` 参数。仅在程序目录放入 `ImageAgent.preview.json`（`{"demoSession":"qa_20261104","mode":"frontend"}`）也可启动同一个隔离预览。session 只允许 1–80 位字母、数字、`-`、`_`；固定根为临时目录下 `ImageAgentWindowsDemo-<session>`。离线模式始终是假凭据/假 transport；持久化的仅是 endpoint 存在标记，用户输入的 Key 不保存。

离线可使用任意 Key，`fail` 模拟验证失败；`https://offline-network-failure.invalid` 模拟网络失败。流式演示按钮可运行或中断预览；文字含 `[interrupt]` 模拟流中断、`[native]` 模拟未验证内置图片恢复。所有按钮仍走正常 Core/状态机。正式 Windows 发布包必须排除 preview sidecar。

显式 `--configure-from-environment` 只在 Windows 正常模式启用，只消费 `OPENAI_BASE_URL` 与 `OPENAI_API_KEY` 并立即清除本进程变量。普通启动不读取这些变量。不会读取 Mac Keychain、cc-switch 或其他生产配置。

## 实现和验证位置

| 完整功能矩阵范围 | 实现 | 已运行的跨平台证明 |
| --- | --- | --- |
| 启动/外观、连接/错误页、图标、系统主题 | Desktop/Program.cs、MainWindow.cs、Assets | 完整 Release 编译；正常非 Windows guard、非法 session 测试 |
| 会话、消息精确复制、取消后返回编辑、草稿/附件隔离 | Core/WorkspaceState.cs、Desktop/MainWindow.cs | EngineStateTests 中 source/draft/取消/冲突测试 |
| IME/撤销/Enter/Ctrl、图片粘贴/文件/导出/缺图/棋盘格 | Desktop/MainWindow.cs、ClipboardReader.cs | 图像和状态测试；原生剪贴板/IME 需 Windows 实机记录 |
| 同窗口工作区、钢笔/方框/平移/缩放、评论/擦除、session/acceptance | Desktop/EditorOverlay.cs、Core/WorkspaceState.cs | Swift goldens、来源接受/评论与陈旧 session 测试；界面检查见验证说明 |
| 图片/规划选择、API/key 草稿、保存/回滚/来源代次 | Core/Models.cs、Credentials.cs、WorkspaceState.cs、Desktop/SettingsWindow.cs | 参数严格匹配、补偿、最新无关设置、Key 清除/手输保持测试 |
| 真 SSE、顶层 prompt 解码、严格终态、无重试、reply/generate/edit | Core/APIClient.cs、ResponseStreaming.cs、AgentEngine.cs | UTF-8/转义/CRLF、EOF/DONE、身份/重复键、完整终态、精确调用次数测试 |
| EXIF/RGB ICC/alpha、有限 ROI、逆 alpha mask、向内柔化、选区外原字节 | Core/Imaging.cs、RegionEditing.cs | 全部 Swift 几何/合成样例；P3、JPEG/WebP 原 ICC、八方向 TIFF、透明 PNG 往返测试 |
| 原始字节先落盘、native 未验证标记、合成/登记/重启失败恢复 | Core/Storage.cs、AgentEngine.cs | 原始字节后故障、全部 native 字节优先、取消后有效图、最终回复失败和幂等重开测试 |
| Swift JSON/SQLite 兼容、有限记忆、Unicode、路径与所有权 | Core/Models.cs、Storage.cs | 2001 epoch、五表重开/级联、24h/轮/字素预算、未来/重置/主动旧参考、路径逃逸拒绝测试 |
| 离线 session、自检、显式环境配置、系统文件交互 | Core/Offline.cs、Diagnostics.cs、ProductionInstance.cs、Desktop/Program.cs、WindowsActivation.cs、MainWindow.cs | 离线自检及独立 CLI local/streaming/region/recovery 报告 + 0 真实网络请求；live 路由仅假 HTTP 验证，系统模块按平台记录 |

当前实现开发主机为 macOS。Windows 原生启动/第二实例前台激活、Credential Manager、截图剪贴板、IME/DPI、多显示器、安装/卸载必须在真实 Windows 运行后才可记录通过。仓库发布脚本生成自包含 PE 和 NSIS 安装程序，并校验两个架构的原生 DLL、运行时和压缩包；安装包未做 Authenticode 签名。详细验证范围见仓库 docs/validation.md；这些检查不能替代 Windows 实机结果。HEIC 等依赖平台编解码器的格式未列入四种正式输入格式，也未宣称已验证。
