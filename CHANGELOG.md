# 更新记录

## v0.1.0 — 首次公开开发测试版（2026-10-07）

应用版本 **0.1.0+7**，源码来自 `codex/mac-liquid-glass`，发布 macOS Apple Silicon DMG。此版本不含 VAD 实验；`main` 保留早期共享基线。

### 界面与桌面体验

- 六个主页面、菜单、表单、文件选择与悬浮字幕改为原生 AppKit；全高度边栏和底部会话控制栏参考 macOS 应用布局。
- macOS 26+ 使用 Liquid Glass 控制层，较早系统使用视觉效果回退；支持明暗主题与降低透明度。
- 加入 LumaCaption 品牌图标，调整窗口按钮、边栏、字幕控制与输入电平布局。
- 权限诊断区分真实采集拒绝、设备错误与需重启状态，显示当前应用路径，便于确认授权副本。

### 识别与翻译

- 支持 `qwen3.8-livetranslate-flash-realtime` 实时音频翻译，保留 Qwen 3.5 协议兼容；在线实时路线上传 16 kHz PCM 音频。
- 本地 Whisper 使用 Metal，失败时回退 CPU；文本路线通过 `qwen-mt-flash` 流式翻译，仅提交原文文字。
- 本地文本模式第 1 秒触发预览，后续基础间隔 500ms，按推理耗时自适应放慢；最终任务优先，待处理预览只保留最新一份。
- 提前显示和翻译稳定词语前缀，可修订尾部采用次级颜色；确认后校正完整译文。预览不计入确认导出。
- 启动时后台校验、加载已选模型并用合成静音暖机，模型在会话间常驻；首次启动不自动下载模型。
- 提供离线原文字幕、系统声音/麦克风采集、独立悬浮窗、暂停/停止、可选本地历史和 TXT/SRT/VTT 导出。
- 凭据保存在系统安全存储，按实际服务地址区分；原始音频不落盘，字幕默认仅保留在内存。

### 验证与限制

- macOS arm64 已构建，采用 ad-hoc 签名，未进行 Developer ID 签名或公证。Whisper 权重不随包提供。
- 500ms 为预览调度间隔，不是最终译文延迟承诺。公开短样本的实时节奏对照见 [发布分支测试记录](https://github.com/KiritoSkyWalker/LumaCaption/blob/codex/mac-liquid-glass/docs/testing.md)。
- Windows 安装包与实机、麦克风真实录音、完整悬浮窗手工交互及多显示器/全屏场景尚未完成验收。
- 开发包更新可能需要系统对当前副本重新授权。系统共享提示的位置由 macOS 管理。

## 尚未发布的分支

- **`codex/vad-endpoint-drain`（0.1.0+8 实验）**：Silero VAD、384ms 非语音端点、过时在途预览取消、正常暂停/停止排空已收到的音频，保留真实末尾余量。VAD 判断声音活动，可能在语义未完整时切句；真实 EOF 收尾尚未改善，未纳入本次 Release。见 [实验说明](https://github.com/KiritoSkyWalker/LumaCaption/blob/codex/vad-endpoint-drain/docs/vad-endpoint.md)。
- **`codex/windows-material3`**：Windows Material 3 界面方向，保留 CPU Whisper；等待 Windows 编译与设备验收。

## 早期共享基线（2026-10-06）

`main` 的应用版本为 0.1.0+1，建立 Flutter/Dart 共享业务与 Swift/C++ 原生桥接，包含 CPU Whisper、Qwen 3.5/text 翻译适配器、采集、悬浮字幕、历史与导出、模型校验及桌面构建脚本。该基线与当前 macOS Release 的原生界面和性能策略不同。
