# LumaCaption

macOS/Windows 实时字幕应用，共享 Dart 识别、翻译与存储逻辑。macOS 界面由 AppKit 完整承载，Windows 界面使用 Flutter。当前 0.1.0 为开发测试版；平台验收状态见 [docs/testing.md](docs/testing.md)，协议与能力边界见 [docs/feasibility.md](docs/feasibility.md)。产品完整要求保存在 [docs/product-spec.zh.md](docs/product-spec.zh.md)。

当前分支 `codex/mac-liquid-glass` 的六个主页面、底部会话控制栏、菜单、表单、文件弹窗和悬浮字幕均为原生 AppKit。全高度边栏包含系统窗口按钮、品牌图标与 LumaCaption 名称，布局参考 Apple Music。Liquid Glass 用于控制和悬浮层，正文保持清晰可读；Flutter Engine 仅运行后台业务。Windows Material 3 界面位于 `codex/windows-material3`。共享基线保留在 `main`。设计与验证说明见 [docs/ui-variant.md](docs/ui-variant.md)。

## 使用

macOS 打开 `dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`，拖动 LumaCaption.app 到 Applications，然后启动。测试包采用 ad-hoc 签名，未 Developer ID 签名或公证。应用无需 Flutter、Python、Node 或编译工具。

1. 在「模型管理」下载多语言 tiny/base/small，或导入兼容 GGML `.bin`。先选择「使用」加载。首次启动不自动下载。
2. 在「实时字幕」选择工作模式和音频来源。离线模式完全本地；千问实时模式上传音频；文本模式仅上传原文文字，含可修订预览。
3. 在线模式在「翻译服务」填写地域、Workspace、Endpoint、模型 ID、API Key。Key 存在系统安全存储；更换主机不会沿用旧主机凭据。
4. 开始时按操作系统提示授权；可暂停/继续、正常停止等待最后一句，或立即停止上传。
5. 打开悬浮窗；macOS 从菜单栏或 ⌃⌥⌘L 恢复鼠标交互，Windows 从托盘或 Ctrl+Alt+I 恢复。主窗口关闭会隐藏，退出会停止采集。
6. 「历史与导出」提供 TXT/SRT/VTT。默认字幕只在内存，原始音频不落盘、不回放，无遥测。
   开启历史保存后，已确认字幕可跨启动浏览；SRT/VTT 按会话导出，全部会话可导出 TXT。

macOS 开发包更新可能改变 ad-hoc 代码身份，多个同名副本也容易混淆授权对象。「设置与诊断」显示正在运行的应用路径，并区分开始时确认、当前副本被拒绝与需重启的状态。若开关已开启但仍收到系统拒绝，请完全退出应用；必要时在「屏幕与系统音频录制」移除旧条目，再添加当前 `/Applications/LumaCaption.app` 后重新打开。权限以真实 ScreenCaptureKit 启动结果为准，音频设备启动错误不会再归类为未授权。

实时音频模式默认使用 `qwen3.8-livetranslate-flash-realtime`，按 16 kHz PCM 分帧上传，仅请求文字输出；已有 3.5 配置继续使用对应协议。本地识别＋文本翻译使用 Whisper 与 `qwen-mt-flash`，仅上传原文文字。前两秒开始本地识别预览，随后每秒检查；连续两次识别一致的前缀提前翻译，原文改写会撤回旧预览，完整原文确认后校正译文。保留最长八秒识别上下文，原文预览重译至少间隔 1.5 秒音频，避免每个字都发请求。译文增量显示，预览和中断译文不会作为确认结果导出；提前翻译可能增加请求次数。两种服务的密钥分别按实际 Endpoint 存入钥匙串；Workspace 占位符在保存和读取凭据时一致展开。

0.1.0+5 用同一段 11 秒公开音频做三轮真实静音测试，本地 tiny＋MT 首个可修订译文中位数为 3.61 秒，旧版仅翻译确认原文为 9.01 秒；新版首个确认译文仍需 8.80 秒。用户所选 small 在 CPU 上单轮首译为 9.89 秒，等待主要发生在提交 MT 之前。详见 [预览策略实测](docs/whisper-mt-preview-benchmark.md)。这些时间从输入音频开始计算，模型加载和服务准备另计；首轮有 7.07 秒准备异常，不能称为点击开始后 3.61 秒。此前 Qwen 3.8 首译 3.28 秒及 MT 收尾长延迟见 [历史基线](docs/qwen38-whisper-mt-benchmark.md)。

## 构建

固定 Flutter 3.47.6（Dart 3.13.5），`pubspec.lock` 锁定依赖；Whisper v1.8.1。模型权重不打包。

macOS arm64：需要 Flutter、CMake、git，以及 macOS 26+ SDK（Xcode 或可用 CLT）。macOS 26+ 使用原生 Liquid Glass，13.3–15 使用 NSVisualEffectView。降低透明度时使用实色背景。脚本可用本项目 `.tools/flutter/bin/flutter`，或环境变量 `LUMA_FLUTTER` 指定已安装 Flutter。
当前经过验证的 macOS 入口是下面的构建脚本；`macos/` Xcode scaffold 尚未集成原生桥接，不使用它作为完整开发运行入口。

```sh
flutter pub get --enforce-lockfile
dart analyze lib test
flutter test
LUMA_FLUTTER="$(command -v flutter)" scripts/build_macos.sh
```

Windows x64：Windows 10/11、VS2022 Desktop development with C++、Windows SDK 10.0.22621+、CMake、git、Flutter 3.47.6、Inno Setup 6.4.3。

```powershell
flutter pub get --enforce-lockfile
dart analyze lib test
flutter test
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1
```

Windows 脚本生成真正 Inno Setup 安装器，包含 Flutter engine、assets、Whisper DLL 和 app-local VC143 CRT，支持快捷方式及卸载。脚本尚未在 Windows 运行。双平台 CI 在 `.github/workflows/build.yml`，只有成功 CI 的产物才算已构建。

macOS 正式签名：设置 `LUMA_SIGN_IDENTITY` 为自己的 Developer ID Application 身份，脚本启用 Hardened Runtime。可用 `xcrun notarytool submit <dmg> --keychain-profile <自己的配置> --wait` 及 `xcrun stapler staple <dmg>`；证书和凭据不进入源码。没有正式身份时保持可安装的 ad-hoc 测试包。

## 无 Key 的真实文件测试

普通测试使用本地 mock 协议，不产生 API 费用。使用你有权处理的 16-bit PCM 或 float32 WAV；可在「设置与诊断」中选择文件，先切换到离线模式。

原生库构建后可显式运行 FFI 验收：

```sh
LUMA_TEST_MODEL=/绝对路径/ggml-tiny.bin \
LUMA_TEST_WAV=/绝对路径/测试.wav \
flutter test test/whisper_integration_test.dart --reporter expanded
```

该验收期待一段包含英文 country 的音频，开发验证使用 whisper.cpp 的 `samples/jfk.wav`。本仓库没有分发音频；用户也可提供自己的 WAV 并通过 GUI 验证，不限定词句。

完整 GUI 可显式注入真实 WAV（不上传、不修改普通设置）：

```sh
dist/LumaCaption.app/Contents/MacOS/LumaCaption \
  --test-model=/绝对路径/ggml-tiny.bin \
  --test-wav=/绝对路径/测试.wav \
  --test-output=/绝对路径/验收结果.json
```

此入口为明确测试模式，使用真实模型、音频、字幕和悬浮窗；没有生产 mock 或伪造输出。

显式在线静音验收可增加 `--test-mode=realtime` 或 `--test-mode=text`、`--test-online=true --test-paced=true --test-source-language=en --test-target-language=zh`。它只读取指定 WAV，通过正常业务路径按 100 ms 分帧处理，不播放、不采集麦克风，不修改普通设置或历史。密钥读取已保存的系统安全存储，不接受密钥命令行参数；本地路径需 `--test-model`，实时云端路径不加载本地 Whisper。省略在线标记时仍为离线验收。报告区分模型加载、服务准备、首段原文、首段译文、末句收尾和音频帧调度；字幕时间未知时不会编造时间。

受控原生采集测试可将 `--test-wav=...` 换为 `--test-source=system` 或 `--test-source=microphone`，再指定 `--test-duration=20`（1–120 秒）。它只运行离线模式，结束后停止采集，报告帧数、电平、转写和悬浮窗原生属性，不写普通设置或历史。测试音频需另行播放。命令行与正常 GUI 的 TCC 授权上下文可能不同；本机 CLI 的系统采集被 TCC 拒绝，正常 GUI 路径已实际通过。

## 当前未完成

Windows AI Speech SDK 集成、MSIX、Windows 安装产物与实机验收；麦克风、悬浮窗完整手工交互验收；其它 OpenAI-compatible 服务真实联调；Metal 推理、Intel/Windows ARM64；术语与高级文本参数的完整 GUI、可配置全局快捷键 UI、英文界面完整本地化。性能数字只代表记录的测试条件；此前 tiny 系统声音样本出现过误识别和漏词。
