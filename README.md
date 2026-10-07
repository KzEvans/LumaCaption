# LumaCaption

Flutter/Dart 主体 + Swift/C++ 原生桥接的 macOS/Windows 实时字幕应用。当前 0.1.0 为开发测试版；平台验收状态见 [docs/testing.md](docs/testing.md)，协议与能力边界见 [docs/feasibility.md](docs/feasibility.md)。产品完整要求保存在 [docs/product-spec.zh.md](docs/product-spec.zh.md)。

## 使用

macOS 打开 `dist/LumaCaption-0.1.0-macos-arm64.dmg`，拖动 LumaCaption.app 到 Applications，然后启动。测试包采用 ad-hoc 签名，未 Developer ID 签名或公证。应用无需 Flutter、Python、Node 或编译工具。

1. 在「模型管理」下载多语言 tiny/base/small，或导入兼容 GGML `.bin`。先选择「使用」加载。首次启动不自动下载。
2. 在「实时字幕」选择工作模式和音频来源。离线模式完全本地；千问实时模式上传音频；文本模式只上传确认原文。
3. 在线模式在「翻译服务」填写地域、Workspace、Endpoint、模型 ID、API Key。Key 存在系统安全存储；更换主机不会沿用旧主机凭据。
4. 开始时按操作系统提示授权；可暂停/继续、正常停止等待最后一句，或立即停止上传。
5. 打开悬浮窗；macOS 从菜单栏或 ⌃⌥⌘L 恢复鼠标交互，Windows 从托盘或 Ctrl+Alt+I 恢复。主窗口关闭会隐藏，退出会停止采集。
6. 「历史与导出」提供 TXT/SRT/VTT。默认字幕只在内存，原始音频不落盘、不回放，无遥测。
   开启历史保存后，已确认字幕可跨启动浏览；SRT/VTT 按会话导出，全部会话可导出 TXT。

## 构建

固定 Flutter 3.47.6（Dart 3.13.5），`pubspec.lock` 锁定依赖；Whisper v1.8.1。模型权重不打包。

macOS arm64：需要 Flutter、CMake、git 和 Xcode 或可用 CLT SDK。脚本可用本项目 `.tools/flutter/bin/flutter`，或环境变量 `LUMA_FLUTTER` 指定已安装 Flutter。
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

受控原生采集测试可将 `--test-wav=...` 换为 `--test-source=system` 或 `--test-source=microphone`，再指定 `--test-duration=20`（1–120 秒）。它只运行离线模式，结束后停止采集，报告帧数、电平、转写和悬浮窗原生属性，不写普通设置或历史。测试音频需另行播放。命令行与正常 GUI 的 TCC 授权上下文可能不同；本机 CLI 的系统采集被 TCC 拒绝，正常 GUI 路径已实际通过。

## 当前未完成

Windows AI Speech SDK 集成、MSIX、Windows 安装产物与实机验收；麦克风、悬浮窗完整手工交互验收；真实 Qwen API 联调；Metal 推理、Intel/Windows ARM64；术语与高级文本参数的完整 GUI、可配置全局快捷键 UI、英文界面完整本地化。性能数字只代表记录的测试条件；tiny 实时样本有误识别和漏词。
