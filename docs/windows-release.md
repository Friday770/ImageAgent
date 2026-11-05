# Windows 安装

前往 https://github.com/Friday770/ImageAgent/releases/latest ，在 Assets 中选择安装包：Intel/AMD 电脑选择 x64；Snapdragon 等 Windows ARM 电脑选择 ARM64。安装版使用 `Setup.exe`，便携版完整解压后运行 `ImageAgent.exe`。

首次运行在界面中填写自己的 API URL 和 Key，验证后连接。示例地址 `https://api.example.com/v1` 不是真实服务。Enter 换行，Ctrl+Enter 发送，Ctrl+V 粘贴截图；Ctrl+, 打开设置。

点击图片在当前窗口进行缩放和编辑。标注使用细红框或闭合钢笔圈选，填写要求后提交；原图与结果分别保存。已取消请求可返回编辑，不会自动重发。

数据保存在 `%LOCALAPPDATA%\ImageAgent`，首次启动自动创建空数据库，Key 按服务地址保存在 Windows 凭据管理器。发布包不含数据库、已保存 API 配置或用户图片。卸载保留数据。

Windows 包为自包含版本，无需另装 .NET。当前 Windows 安装包未签名，Windows 真机验证范围见 [验证说明](validation.md)。更多开发与诊断命令见 [Windows 说明](../windows/README.md)。
