# LumaCaption 0.1.0 验收记录

更新：2026-10-06。这里区分源码实现、模拟协议测试、真实模型运行和设备验收。

## 测试环境

- Apple M2、16 GiB 内存、arm64；macOS 27.2 beta（26B5091g）。
- Flutter 3.47.6 / Dart 3.13.5；Swift 6.2、AppleClang 17；CLT SDK，未安装完整 Xcode。
- CMake 4.4.4、Ninja 1.13.2；whisper.cpp v1.8.1，CPU + Accelerate，未启用 Metal 推理。
- tiny 多语言 GGML，77,691,713 字节；来源与 SHA256 见 assets/models.json。模型不随安装包分发。

## 自动化结果

`dart analyze lib test`：无问题。`dart analyze scripts/artifact_manifest.dart`：无问题。

`flutter test --reporter expanded`：**24 项通过，1 项可选真实 FFI 测试跳过**。普通测试不使用 Key、不访问翻译服务、不产生 API 费用。覆盖：

- PCM downmix/饱和，48→16 kHz 带抗混叠的重采样，以及跨帧连续性。
- VAD、长句上限、收尾音频、同一片段的 partial 修订与 final 确认。
- 模型 Range 206 续传、200 重新下载、完整缓存离线校验、损坏缓存清理与重试、格式/hash 拒绝。
- generation/revision 过滤、CJK 重叠去重、未知时间不伪造、SRT/VTT 单调与重叠处理。
- 千问 3.5 text/stash/done、独立原文 ID、会话配置/完成；本地 WebSocket 服务验证真实 PCM16 发送及最后一句收尾。
- Qwen-MT 单 user message 请求，有限并发文本翻译排序、过时 generation 取消；凭据不进入普通配置。
- 1120×800、860×650 的全部六个桌面页面布局与缺少凭据的操作提示。
- 历史恢复只保留 final；关闭保存后不写入新字幕；再次开启保存；会话音频时间线分别导出；未知历史版本保持原文件。

本机 `flutter analyze` 的 LSP 初始化在中文工作目录发生 UTF-8 解码错误，使用同一 SDK 的 `dart analyze` 成功。分析器自身问题没有计作应用测试通过。

## 真实模型和安装验收

显式设置 `LUMA_TEST_MODEL` / `LUMA_TEST_WAV`，运行 test/whisper_integration_test.dart：**通过**。输入为上游 samples/jfk.wav（约 11 秒）；输出包含预期 country 文本，时间范围合法，原生上下文释放完成。一次实测约 2981 ms（包括加载），过程 RSS 321,323,008 字节；这不是峰值内存指标。

GUI 中实际完成 tiny 模型下载、可信 hash 校验和加载。实际 CPU 后端如实显示，未把硬件 GPU 信息当作推理加速。

最终 DMG 挂载后，将 .app 安装到 `$HOME/Applications/LumaCaption.app`，卸载映像，`codesign --verify --deep --strict` 通过。安装副本运行真实 WAV → FFI → 字幕 → 独立原生悬浮窗流程：收到 110 帧、11.0 秒文件音频，生成两条 final，检测到的丢弃为 0；最后 3.5 秒窗口推理 868 ms、RTF 0.248。停止后原生 running=false。峰值 RMS=0.382；没有播放声音，没有麦克风采集或上传。结果见 build/installed-final.json。RTF 是最后一个窗口的实测，不是全会话平均或端到端延迟；尚未记录首字/最终字幕端到端延迟与峰值内存。WAV 测试不等于系统声音采集验收。

原生采集与悬浮窗诊断的结果在下一节记录。GUI 自动化的截图/状态读取在这台 beta 系统出现 ScreenCaptureKit -3811/-3812 错误；没有用其它截图手段绕过它，因此拖动、多屏、真实按键/鼠标恢复及全屏覆盖仍需人工验收。

## 原生采集与窗口验收状态

- 系统声音：**真实 GUI 路径通过**。用户完成授权后，从已安装 .app 正常启动，GUI 开始采集，播放约 11 秒上游英语样本。生成 3 条 final；GUI 正常停止并通过 NSSavePanel 导出 build/system-original.txt。tiny 输出有漏词和误识别，不把这次结果称为准确率验收通过。CLI 启动同一包仍返回 TCC 拒绝，正常 GUI 没有该错误；权限上下文差异是推测，未修改开发工具权限或 TCC 数据。
- 麦克风：真实 AVAudioEngine 路径已编译，设备枚举与权限查询通过；用户选择保持安静，**本次未做麦克风录音或播放测试**。
- 悬浮窗：**真实 NSPanel 属性检查通过**。安装后 visible=true、opaque=false、isKeyWindow=false、canBecomeKey=false；开启穿透得到 clickThrough=true，调用原生恢复入口后为 false；全局快捷键注册成功。结果由原生 NSPanel 属性返回，非 Flutter 预览状态。实际键盘触发、拖动、托盘、DPI/多屏交互仍待人工验收。
- 权限拒绝、休眠、热插拔、多显示器、Spaces/独占全屏：路径已实现，未完成设备验收。
- Qwen 3.5 / Qwen-MT / OpenAI-compatible：模拟服务验证通过；未使用真实 Key 联调。首次在线测试由用户显式发起，可能产生小额费用。
- Keychain / Credential Manager：桥接已实现；未用真实凭据验证读写。普通配置脱敏测试通过。
- Windows：C++ WASAPI、layered HWND、托盘、Credential Manager 和安装脚本已实现；本机没有可用 Windows SDK/虚拟机，**未编译，未生成安装器，未实机验收**。CI YAML 不是运行成功证明。
- Windows AI Speech：仅调查及明确的未集成诊断；SDK 编译、持续外部音频识别和 MSIX 尚未完成。

## 构建与交付

macOS 产物为 dist/LumaCaption-0.1.0-macos-arm64.dmg，内含完整 .app、Flutter AOT/engine、Whisper 原生库和许可证。最低 macOS 13.3、arm64，模型按需下载。ad-hoc 签名，无 Developer ID、无公证，未开启 Hardened Runtime；正式身份构建时脚本才开启 Hardened Runtime。

每次构建生成 `.sha256` 和 `.artifact.json`，记录文件、平台、架构、版本、实际 SHA256、签名类型、构建时间和源码 revision（本次没有 Git commit，记为 null）。当前文件以 dist 内的清单为准。

构建命令与使用方法见 README.md。macOS 实际交付走 scripts/build_macos.sh 的 CLT 原生宿主；仓库 macos/ 的 Flutter Xcode scaffold 尚未集成桥接，不应直接用 `flutter run -d macos` 声称完整功能。Windows scripts/build_windows.ps1 需要 Windows + VS2022/Windows SDK + Inno Setup；待该环境中运行及验证。

本次最终 DMG：10,924,497 字节，SHA256 `1331b1160a8f494d4e19060f803b620979dc0eb09e22aec4f8d21bcaa4daaa67`。已安装位置 `$HOME/Applications/LumaCaption.app`。采用 ad-hoc 的开发更新可能改变 TCC 认可的代码身份；如更新后系统要求重新授权，请对当前安装副本授权。
