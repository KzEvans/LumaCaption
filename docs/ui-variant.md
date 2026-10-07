# macOS 完整原生界面与 Liquid Glass

当前分支 `codex/mac-liquid-glass`，源码重构提交 `d41f113`。共享基线在 `main`，Windows Material 3 界面独立保留在 `codex/windows-material3`。

## 界面结构

macOS 的可见界面全部使用 AppKit。`NSSplitViewController` 与原生 source list 承载六个页面，`NSToolbar` 提供开始、暂停、悬浮窗和侧边栏操作；标题、窗口按钮与系统菜单使用 macOS 行为。

| 页面 | 原生内容与交互 |
| --- | --- |
| 实时字幕 | 声音来源、设备与模式菜单；输入电平；状态、隐私提示；可选择复制的流式字幕；玻璃控制条 |
| 模型管理 | 模型规格、安装与使用状态；下载、续传、暂停、取消；进度；删除确认；原生文件与目录 Sheet |
| 翻译服务 | 分模式配置；安全凭据输入；保存与显式连接测试；页面切换保留草稿；离线模式显示本地模型入口 |
| 字幕外观 | 系统玻璃预览；显示内容、字号、不透明度、明暗主题；鼠标穿透与恢复 |
| 历史与导出 | 会话筛选、搜索、文本选择复制；TXT/SRT/VTT；历史保存开关；原生导出与清空确认 Sheet |
| 设置与诊断 | 实际权限状态；系统隐私设置入口；静默 WAV 验证；模型、速度、耗时与诊断记录 |

悬浮字幕使用独立、不抢焦点的 `NSPanel`，背景为系统玻璃，文本使用语义颜色。保留拖动、缩放、菜单栏控制、全局恢复快捷键和多屏位置恢复。

## 材质与原生行为

按 Apple 指南把玻璃用于控制、导航与浮动层，正文和表单以可读性为主。macOS 26+ 的标准控件采用系统外观，自定义浮动控制和字幕使用正式 `NSGlassEffectView`。13.3–15 回退为 `NSVisualEffectView`；开启“减少透明度”时使用不透明语义背景，监听系统辅助功能显示变化。材质不透明度不降低字幕文字的透明度。

原生系统字体、SF Symbols、强调色、选中状态、焦点环、滚动与窗口行为贯穿所有页面。⌘1–6 切换页面，⌘, 打开设置，⌘Return 开始或停止，⌘P 暂停或继续，⌘L 显示或隐藏悬浮字幕，⌘F 查找字幕，⌃⌘S 折叠侧边栏。剪切、复制、粘贴、撤销和重做走原生响应链。

参考：[Apple Liquid Glass 采用指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[为 macOS 设计](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)、[NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)。未使用实验性的 effectIsInteractive 接口。

## 业务连接

`native/macos/main.swift` 启动允许无视图运行的 Flutter Engine；macOS 不创建 FlutterViewController，也不挂载 Flutter 内容页。识别、翻译、模型和存储继续使用真实 Dart 控制器与原生音频、Whisper、钥匙串桥接。

`lib/app/mac_workbench.dart` 将显示状态发送到 `lumacaption/design`，接收实际操作。PCM 和已保存凭据不进入界面状态。捕获期间锁定声音及服务配置；界面更新合并，只有当前页面更新控件；字幕文本保持选择与滚动位置。API Key 只通过用户的保存操作交给安全存储，成功后清空输入；连接测试仅由按钮明确发起。

旧的“原生导航 + Flutter 正文”协调器已移除。Flutter shell 仅保留为其它平台入口和组件回归测试，不能用它的测试结果宣称原生 macOS 布局通过。

## 构建与验证

使用 `scripts/build_macos.sh`；需要 macOS 26+ SDK，部署目标 13.3、arm64。`macos/` Xcode scaffold 尚未整合桥接。测试包为 `dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`，开发签名，尚未 Developer ID 签名或公证。

实际应用已检查六页原生辅助功能树、页面切换、明暗外观、键盘焦点、未保存草稿、原生文件 Sheet、历史搜索、TXT 实际导出与取消清空。真实离线 WAV 验收确认 AppKit 文本区收到字幕，原生玻璃类型与不抢焦点属性正确。旧版可见 Flutter 内容区的 AXTree 更新问题不再复现；没有修改 Flutter 引擎或系统辅助功能权限。

完整 VoiceOver 朗读、13.3–15 回退环境、系统减少透明度、多屏与全屏覆盖仍未实机验收。保持安静，未播放声音、采集麦克风或调用真实在线 API。更详细的证据与包清单见 [testing.md](testing.md)。
