# LumaCaption 可行性与验证记录

核查：2026-10-04、2026-10-06。当前实现为 0.1.0 开发测试版。

| 能力 | 当前契约与选择 | 最小验证结果 |
| --- | --- | --- |
| 主体界面 | Flutter 3.47.6 / Dart 3.13.5，单一 ChangeNotifier 状态管理 | 发布 AOT 框架构建、真实 macOS GUI 启动 |
| macOS 系统声音 | ScreenCaptureKit，SCStream 仅注册 audio 输出；无屏幕图像消费者、保存或上传；显示器 filter 为框架要求 | Swift 编译通过；授权后真实 GUI 采集、tiny 转写、正常停止与 TXT 导出通过，准确率有限 |
| macOS 麦克风 | AVAudioEngine；AVAudioConverter 转真实 16 kHz mono float32 | Swift 编译通过，设备/权限查询通过；真实录音待验收 |
| Windows 系统声音/麦克风 | WASAPI shared-mode loopback / capture，设备真实混音格式转换，单独来源 | 已实现 C++ 源码；本机无 Windows SDK，尚未编译或录音验收 |
| 本地识别 | whisper.cpp v1.8.1，小型 C ABI + Dart FFI，持久工作 isolate，取消回调 | arm64 原生库构建、tiny 多语言模型真实推理通过 |
| 模型管理 | 上游 GGML，固定仓库 revision，LFS SHA256；Range 续传、哈希/头部校验、临时文件替换 | GUI tiny 下载/校验/加载通过；中断逻辑通过本地 HTTP 测试 |
| 悬浮字幕 | macOS NSPanel / Windows layered HWND 独立窗口；置顶、无焦点、透明、交互恢复、托盘 | macOS 编译与独立 NSPanel 显示；完整交互验收见 testing.md |
| 密钥 | Keychain / Credential Manager；scheme+host+port 对应独立 account | macOS 实际配置、保存与真实 API 读取通过；Windows 未实测 |
| 千问实时翻译 | 默认 3.8 delta/done；保留 3.5 text/stash 配置兼容，仅文字输出 | 3.8 真实 API 静音文件联调通过；3.5 仅模拟协议验证 |
| Whisper＋Qwen-MT | 本地确认原文和稳定预览以文字上传；增量译文可修订，最终识别后校正 | Qwen-MT flash 真实 API 文件联调通过；预览策略验收见 testing.md |
| Windows AI Speech | 与传统 SpeechRecognition、Live Captions 私有实现区分 | 调研完成，基础版提供未集成诊断；实现和 MSIX 未完成 |
| 安装包 | macOS 完整 .app + DMG；Windows Inno Setup + app-local VC runtime | macOS 测试 DMG 已生成；Windows 未生成 |

## 协议契约

千问连接模板：北京 `wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime`，新加坡 `wss://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/api-ws/v1/realtime`。Bearer 认证、model 查询参数；3.5 会话用 `modalities:["text"]`、`input_audio_format:"pcm"`、`sample_rate:16000`、`translation.language`。默认 server VAD，不重复手动 commit。停止发送 `session.finish`，等待 `session.finished` 或明确超时。

3.5 的 `response.text.text` text/stash 按示例覆盖可修订显示，`response.text.done` 的完整文本权威校正。3.8 使用独立 delta 解析器，`session.output_modalities` 与嵌套 `audio.input.turn_detection` 配置；源文/译文增量追加，done 校正完整文本，响应完成事件决定 final。两协议不共用增量语义。连接失败不自动更换 provider、不上传本地回退、重连不补传旧音频。当前 realtime 是 Qwen 专用协议适配，不能只改模型 ID 就调用其它厂商音频服务。

[Qwen 官方模型与协议说明](https://www.alibabacloud.com/help/en/model-studio/qwen3-5-livetranslate-flash-realtime)、[客户端事件](https://www.alibabacloud.com/help/en/model-studio/live-translator-client-events)、[服务端事件](https://www.alibabacloud.com/help/en/model-studio/live-translator-server-events)、[Qwen-MT](https://www.alibabacloud.com/help/zh/model-studio/machine-translation)。服务端独立事件页 10-06 抓取失败；核心模型页的 3.5 事件与示例可访问。

Qwen-MT 使用一个 user message 与 `translation_options`；OpenAI-compatible 适配器独立使用 system 翻译指令、user 原文，不提交 tools。自定义 header/数值参数有白名单。文本翻译共享持久 HTTP client；单请求取消不关闭其它并发请求。稳定预览仍可能在后续识别中改写，匹配前缀不构成 ASR 的最终保证，因此预览译文仅供实时显示。GUI 当前覆盖基础配置；术语表、上下文和额外请求头目前只在适配器 API 中提供，控制器尚未自动传递上下文。

## 平台范围

Flutter 当前官方支持 macOS 12–27、Windows 10/11 的 x64/arm64；本包实际最低 **macOS 13.3**，因为 CPU BLAS 构建使用该版本 Accelerate API。只交付 arm64，Intel 未构建。Windows 基础安装器目标 Windows 10 22H2 x64，Windows ARM64 尚未构建。

[Flutter 平台范围](https://docs.flutter.dev/reference/supported-platforms)、[桌面开发](https://docs.flutter.dev/platform-integration/desktop)、[macOS 构建](https://docs.flutter.dev/deployment/macos)、[Windows 构建](https://docs.flutter.dev/platform-integration/windows/building)。

WASAPI loopback 支持 shared-mode 渲染端点，1703+ 支持事件驱动 loopback。它不需要虚拟声卡/立体声混音，不保证受保护音频或独占输出。设备失效/睡眠时终止当前采集，重启新 generation，而不是把旧设备结果混入新会话。

[WASAPI 官方说明](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)、[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)。

Windows AI Speech 指南目前列 Windows 11 24H2 build 26100+、WinAppSDK 1.7.1+，NPU 或支持的 CPU；MSIX `systemAIModels` 身份/能力要求。API 参考当前跳转到 2.0 experimental 视图，与指南版本描述不完全一致，必须在 Windows 实际 SDK 上编译确认。指南的 streaming 示例用 FromAudioDevice，提供 phrase 最终结果；外部 WASAPI 持续音频输入契约没有在本机验证。基础版没有依赖这些新 DLL，明确返回 `sdkNotIntegrated`；不读取私有模型，不声称调用 Live Captions 同款内部模型。

[Windows AI Speech 指南](https://learn.microsoft.com/en-us/windows/ai/apis/speech-recognition)、[SpeechRecognitionModel 参考](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.ai.speech.speechrecognitionmodel)。

## 构建环境与签名

本机 macOS 27.2 beta / arm64，只有 CLT；Swift 6.2 编译器（以工具实际输出为准），AppleClang 17，CMake 4.4.4、Ninja 1.13.2。`flutter build macos` 的标准 Xcode 工作流不能在此环境完成，实际 DMG 使用 `flutter assemble` 生成 AOT 框架并由 swiftc 编译原生宿主，再嵌入 Flutter/Whisper。CLT 中重复 Swift modulemap 通过构建目录 VFS overlay 解决，没有修改系统工具链。

测试包使用 ad-hoc 签名，无 Developer ID、未公证；Hardened Runtime 仅在提供正式签名身份后开启，并用相同证书签全部嵌套代码。未改变系统信任、安全设置或证书。macOS 0.1.0+6 的 Whisper 开启 Metal 并嵌入 GPU 内核源码，移出开发目录的真实推理通过；实际后端从原生上下文回传，失败时回退 CPU。Windows 保持 CPU。Flutter 的图形渲染与 Whisper 推理后端分别判断。

[whisper.cpp 固定版本](https://github.com/ggml-org/whisper.cpp/tree/v1.8.1)、[模型上游](https://huggingface.co/ggerganov/whisper.cpp)。
