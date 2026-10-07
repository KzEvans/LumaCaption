# LumaCaption

让理解，跟上声音。

LumaCaption 是一款桌面实时字幕应用：采集系统声音或麦克风，生成原文与译文，并在独立悬浮窗中显示。当前 macOS 版本使用原生 AppKit 界面，共享识别、翻译与存储逻辑由 Dart 承载。

[下载 macOS 开发测试版](https://github.com/KzEvans/LumaCaption/releases/tag/v0.1.0) · [更新记录](CHANGELOG.md) · [发布版验收记录](https://github.com/KzEvans/LumaCaption/blob/codex/mac-liquid-glass/docs/testing.md) · [第三方许可证](docs/THIRD_PARTY_NOTICES.md)

## 当前 Release

**v0.1.0（应用版本 0.1.0+7）来自 `codex/mac-liquid-glass` 分支，不含 VAD 实验。** `main` 已同步该分支中可用于 Windows 的共享业务改进，保留 Flutter 界面与 CPU Whisper；如需查看或构建当前 Release 的原生 Mac 界面，请切换到发布分支。

安装包支持 **macOS 13.3 及以上、Apple Silicon（arm64）**。macOS 26 及以上使用原生 Liquid Glass，较早系统使用 NSVisualEffectView；启用「降低透明度」时使用实色背景。主页面、全高度边栏、底部会话控制栏、菜单、表单、文件弹窗与悬浮字幕均由 AppKit 实现。

安装包包含运行所需的引擎和原生库，无需安装 Flutter、Python 或编译工具。Whisper 模型按需下载，不随安装包分发。包使用 **ad-hoc 签名，尚未进行 Developer ID 签名或公证**，属于开发测试版。Windows 尚无经过编译与实机验收的安装包，Intel Mac 和 Windows ARM64 也暂无安装包。

## 三种工作模式

| 模式 | 识别与翻译方式 | 提交给在线服务的内容 |
| --- | --- | --- |
| 离线原文字幕 | 本地 whisper.cpp 识别，不调用翻译服务 | 无；不需要 API Key |
| 千问实时音频翻译 | 默认 `qwen3.8-livetranslate-flash-realtime` 流式翻译，仅请求文字输出；保留 Qwen 3.5 协议兼容 | 单声道 16 kHz PCM 音频 |
| 本地识别 + 文本翻译 | 本地 Whisper 识别，再调用 `qwen-mt-flash` 或配置的 OpenAI-compatible 文本服务 | 原文文字，包含可修订预览；原始音频留在本机 |

可下载多语言 tiny / base / small 模型，或导入兼容的 GGML `.bin`。macOS Whisper 使用 **Metal**，初始化失败时回退 CPU，界面显示实际后端。选定模型在启动时后台校验、加载，并通过合成静音暖机；模型在会话之间常驻，暖机不会采集声音或发起翻译请求。

本地文本模式从第 1 秒开始预览，后续根据推理耗时在 **500 ms–3 秒**之间调整间隔。连续识别结果中一致的词语前缀可提前翻译，可修订尾部以次级颜色显示。预览仍可能改写；只有已确认字幕进入历史或 TXT / SRT / VTT 导出。

## 安装与开始使用

1. 从 [v0.1.0 Release](https://github.com/KzEvans/LumaCaption/releases/tag/v0.1.0) 下载 `LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`，将 `LumaCaption.app` 拖入「应用程序」，再启动。Release 同时提供 SHA256 校验文件与构建清单。
2. 在「模型管理」下载或导入模型，点击「使用」加载。首次启动不会自动下载模型。离线模式和本地识别 + 文本翻译模式需要本地模型。
3. 在「实时字幕」选择声音来源和工作模式。首次试用可先选择「离线原文字幕」。
4. 如需翻译，在「翻译服务」填写对应配置：实时模式需匹配密钥的地域、Workspace ID 和模型 ID，Endpoint 留空可使用地域模板；文本模式需填写 Base URL、模型 ID 和 API Key。保存后再开始字幕。在线使用由服务商计费。
5. 按 macOS 提示授权：系统声音使用「隐私与安全性 → 屏幕与系统音频录制」，麦克风使用「麦克风」权限。系统设置的具体名称可能随 macOS 版本变化。
6. 点击「开始字幕」，按需打开悬浮窗。正常停止会等待最后一句完成；「立即停止」会终止当前任务并清空当前会话显示。

系统声音采集通过 ScreenCaptureKit 的音频输出完成，应用不接收、保存或上传屏幕图像；macOS 仍会显示系统的录制或共享状态提示。更新 ad-hoc 开发包后，系统可能要求重新授权当前安装副本。如果设置中已允许但采集仍被拒绝，请完全退出应用，在「设置与诊断」核对应用路径；必要时移除旧授权条目，再添加「应用程序」内的当前副本并重新启动。

关闭主窗口会将应用隐藏，可从菜单栏重新打开；退出应用会停止采集。悬浮窗开启鼠标穿透后，可从菜单栏或 **⌃⌥⌘L** 恢复交互。悬浮字幕支持原文、译文或双语显示，以及字号和透明度设置。

## 数据与隐私

- 原始音频只在内存中处理，不录制到文件、不回放。离线模式不向翻译服务上传音频或字幕。
- 实时翻译模式上传音频；文本翻译模式上传原文文字，包括可修订的提前翻译预览。切换在线模式前请确认所选服务和 Endpoint。
- API Key 保存到 macOS Keychain 或 Windows Credential Manager，不写入普通设置文件。凭据按服务地址区分，更换主机后需单独保存对应凭据。
- 字幕默认只保存在内存。开启「保存历史」后，已确认字幕会写入本地历史；手动导出也会生成字幕文件。
- 应用不包含遥测。提交 Issue 时请去除密钥、真实对话、个人文件路径及其他敏感信息。

## 延迟与当前限制

500 ms 是预览调度的最低间隔，**不是每个词或最终译文的延迟保证**。原文稳定、完整片段确认和翻译服务响应仍需要时间；提前预览会增加计算与请求次数。

0.1.0+7 对同一公开 11 秒英语样本以实时节奏静默输入，并使用真实 `qwen-mt-flash` 翻译为中文，各模型测三轮：

| 指标，中位数 | base | small |
| --- | ---: | ---: |
| 音频开始 → 首个可修订译文 | 2.322 秒 | 2.538 秒 |
| 音频开始 → 首个确认译文 | 8.516 秒 | 8.714 秒 |
| 音频结束 → 最后确认译文 | 0.586 秒 | 1.013 秒 |

模型准备和钥匙串授权等待另计；以上只覆盖一个干净短样本，不代表复杂环境的准确率、逐词延迟或点击开始后的总等待。完整测量口径、范围与离群值见 [500 ms 对照报告](https://github.com/KzEvans/LumaCaption/blob/codex/mac-liquid-glass/docs/whisper-500ms-benchmark.md)。Qwen 3.8 与本地 Whisper + MT 两条路线均有静音在线联调记录，其他 OpenAI-compatible 服务尚未完成真实联调。

macOS 已验证真实模型推理、系统声音采集路径和悬浮窗原生属性。麦克风真实录音、悬浮窗完整手工交互、多屏与全屏场景仍需验收。tiny 模型可能漏词或误识别。Windows AI Speech SDK、MSIX、Windows 实机与安装包、完整英文界面及部分高级翻译配置仍待开发或验证。

## 分支说明

| 分支 | 用途 |
| --- | --- |
| [`main`](https://github.com/KzEvans/LumaCaption/tree/main) | 跨平台共享核心：Flutter 界面、CPU Whisper ABI 2、Qwen 3.8 / 3.5、MT 流式翻译、稳定字幕前缀与 500ms 预览、模型预加载；不含 Silero VAD 或 Mac 原生界面 |
| [`codex/mac-liquid-glass`](https://github.com/KzEvans/LumaCaption/tree/codex/mac-liquid-glass) | 当前 macOS Release 0.1.0+7：原生 AppKit / Liquid Glass、Qwen 3.8、Metal Whisper、稳定前缀与 500 ms 预览、后台暖机 |
| [`codex/windows-material3`](https://github.com/KzEvans/LumaCaption/tree/codex/windows-material3) | Windows Material 3 界面方向；尚待 Windows 编译与设备验收 |
| [`codex/vad-endpoint-drain`](https://github.com/KzEvans/LumaCaption/tree/codex/vad-endpoint-drain) | 基于 macOS 优化版的断句与收尾实验：Silero VAD、过时预览取消、末句排空；未纳入当前 Release |

VAD 判断语音活动与停顿，不保证语义上的完整句子。实验分支的结果应按该分支文档理解。

`main` 的共享同步包括识别队列、提示词上下文、取消与关闭生命周期、后台模型校验和静音暖机、Qwen 3.8 独立协议、MT 流式输出和缓存、字幕修订与确认导出、实际节奏 WAV 测试及分阶段延迟记录。文本模式首个预览约 1s，后续按至少 500ms 自适应调度；仍使用原 RMS 静音分段。3.8 默认使用云端原文，驻留的本地模型只在在线会话中断时提供回退，避免重复原文。Windows 原生采集、凭据和构建脚本保持原有接口；Windows 实机验证仍待完成。共享同步范围与验收见 [测试记录](docs/testing.md)。

## 从源码构建

当前 macOS Release 的源码位于 `codex/mac-liquid-glass`：

```sh
git clone https://github.com/KzEvans/LumaCaption.git
cd LumaCaption
git switch codex/mac-liquid-glass
```

构建本次共享核心使用 `main`，保留 Flutter 界面和 CPU 后端。Windows Material 3 分支的专用界面仍在 `codex/windows-material3`，本次同步目标为 `main`。

依赖版本为 **Flutter 3.47.6 / Dart 3.13.5、whisper.cpp v1.8.1**。Dart 依赖由 `pubspec.lock` 锁定。需要 Git 和 CMake 3.24 或以上；没有本地 Whisper 源码时，CMake FetchContent 会获取固定版本，首次构建需要网络。

```sh
flutter pub get --enforce-lockfile
dart analyze lib test scripts/artifact_manifest.dart
flutter test
```

### macOS arm64

需要 **macOS 26 或以上的 SDK**（Xcode 或可用 Command Line Tools），以编译 Liquid Glass API；应用仍包含较早 macOS 的运行时回退路径。完整应用通过脚本构建：

```sh
LUMA_FLUTTER="$(command -v flutter)" scripts/build_macos.sh
```

产物位于 `dist/`，包含 `.app`、DMG、`.sha256` 与 `.artifact.json`。构建清单记录源码 revision、版本、架构、SHA256 和实际签名类型。`macos/` 中的 Flutter Xcode scaffold 尚未集成完整原生桥接，请使用构建脚本作为完整应用入口。

脚本支持以 `LUMA_SIGN_IDENTITY` 指定自己的 Developer ID Application 身份；公证和证书配置由发布者单独管理，凭据不放入源码。

### Windows x64

先切换到 `codex/windows-material3`。需要 Windows 10/11、VS2022 的 Desktop development with C++、Windows SDK 10.0.22621 或以上、CMake、Git、Flutter，以及 Inno Setup 6.4.3：

```powershell
git switch codex/windows-material3
flutter pub get --enforce-lockfile
dart analyze lib test scripts/artifact_manifest.dart
flutter test
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1
```

脚本目标为包含 Flutter、Whisper DLL 和 app-local VC143 CRT 的 Inno Setup 安装器，Whisper 保持 CPU 路径。此平台尚未实际构建验证。仓库提供 [GitHub Actions 配置](.github/workflows/build.yml)，配置存在不代表运行成功，请以具体运行结果为准。

## 静音测试与反馈

普通测试使用本地 mock 协议，不读取真实 API Key、不访问翻译服务。真实 Whisper FFI 测试需显式提供模型与 WAV：

```sh
LUMA_TEST_MODEL=/path/to/ggml-tiny.bin \
LUMA_TEST_WAV=/path/to/whisper.cpp/samples/jfk.wav \
flutter test test/whisper_integration_test.dart --reporter expanded
```

这项测试预期输入上游 `samples/jfk.wav` 中的英文样本。音频样本和模型权重不在本仓库或默认安装包中分发。在「设置与诊断」也可选择自己有权处理的 WAV，使用离线模式静默验证转写。

反馈问题时请注明分支、应用版本、系统版本、工作模式及脱敏后的复现步骤。发布版详细边界见 [验收记录](https://github.com/KzEvans/LumaCaption/blob/codex/mac-liquid-glass/docs/testing.md)。第三方组件与模型的许可证见 [THIRD_PARTY_NOTICES](docs/THIRD_PARTY_NOTICES.md)。
