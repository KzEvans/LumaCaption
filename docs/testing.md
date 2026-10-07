# LumaCaption 0.1.0 验收记录

更新：2026-10-07。这里区分源码实现、模拟协议测试、真实模型运行和设备验收。

## 权限诊断、窗口控制区与品牌图标（2026-10-07，当前包）

当前源码 `e83a5e6`，包版本 `0.1.0+2`。系统声音开始失败按真实 ScreenCaptureKit 错误分类：-3801 为系统授权拒绝，-3818 为音频流启动失败；麦克风拒绝独立处理。权限查询不把 CG 预检失败直接认定为拒绝，真实启动后刷新状态。失败后底栏恢复为「无法开始字幕」并允许重试。设置页显示正在运行的应用路径，诊断保留原生错误域和代码，不记录路径。

当前安装副本此前位于 `/Applications/LumaCaption.app`，另有用户 Applications 与工作区 dist 同名副本，均为 ad-hoc 签名但代码身份不同。用户截图中授权开关已开启，旧安装副本完全退出、重新打开后仍收到真实 TCC -3801；新包安装到同一路径后也收到 -3801。旧包保存在 `build/installed-backup/LumaCaption-before-0.1.0+2.app`。当前机器没有可用正式签名身份；同名副本与版本变化造成授权不匹配是有依据的推测，未读取或修改 TCC 数据库来确认。已请用户移除旧授权条目并重新添加当前 `/Applications/LumaCaption.app`；当前包系统采集尚待该操作后复验，不能沿用旧包的采集通过结论。

窗口使用透明、没有操作项的 `.unified` NSToolbar，由 AppKit 分配标准窗口控制区域；没有可见标题、侧边栏切换或顶部字幕按钮。边栏恢复 LumaCaption 名称与 24 pt 品牌图标。扁平玻璃字幕气泡与声波图标已转换为 ICNS，并接入 Info.plist、构建脚本和边栏。⌘W 关闭或隐藏入口补齐。GUI 检查品牌、权限与路径说明、底部控制栏和真实字幕内容。系统紫色「窗口共享」入口曾在 AX 中替换红黄绿按钮；它属于 macOS 管理，空工具栏不能保证改变系统的替换行为。

完整 Dart 分析无问题，**35 项测试通过、1 项可选 FFI 跳过**；新增覆盖开始失败后的权限刷新、状态恢复、查询失败不覆盖主要错误与诊断路径脱敏。原生错误分类测试 **4 项通过**，不调用采集或修改系统权限。最终 Swift 编译、arm64 DMG 构建和安装副本深度签名验证通过。

最终包静默真实 WAV 结果 `build/mac-permission-logo-final.json`：status=ok，110 帧、11 秒、2 条 final、0 丢弃；停止后原生采集 running=false。最后 3.5 秒窗口推理 887 ms、RTF 0.254。原生 AppKit 文本区实际显示两条字幕，底栏显示已停止。界面报告 toolbar=windowControlsOnly、toolbarActions=0、fullSizeContentView=true、titlebarTransparent=true、cornerRadius=10；会话栏与悬浮窗为 NSGlassEffectView，不抢焦点与穿透恢复属性通过。运行日志无 AXTree 或约束错误。全程没有播放声音、采集麦克风或调用在线 API；真实系统采集启动被拒绝，没有收到音频。

当前 DMG `dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`：11,079,100 字节，SHA256 `1ce592fa90189786858830e45c4ac4c4cd77c3a196d042d41455dde51fdcba34`。清单记录源码 e83a5e6、构建时无未提交源码；ad-hoc 签名，未公证。当前安装位置为 `/Applications/LumaCaption.app`。

## Apple Music 布局修订验收（2026-10-07，历史记录）

源码 `9cc2ca9` 移除顶部工具栏、可见窗口标题和侧边栏切换按钮，启用透明标题栏与全尺寸内容。全高边栏包含系统红黄绿按钮；导航选中背景加宽。六页共享底部 NSGlassEffectView 会话栏，包含状态、电平、隐私、模型与开始/停止、暂停/继续、悬浮窗、立即停止。自定义按钮、卡片与玻璃表面统一 10 pt 圆角；原生按钮语义、禁用状态、焦点环、窗口和菜单行为保留。

Swift 编译、完整 arm64 打包及签名验证通过。GUI 检查六页在 860×650 最小窗口下的布局、表单滚动、固定底栏、明暗切换并恢复跟随系统、悬浮窗显示/隐藏、系统全屏按钮进入与 Escape 退出。最终包另验证 ⌃⌘F 全屏快捷键。系统权限与音频设备没有修改；没有播放、录音或联网翻译。

最终包静默真实 WAV 验证 `build/mac-music-final.json`：status=ok，110 帧、11 秒、2 条 final、0 丢弃；停止后原生采集 running=false。最后 3.5 秒推理 714 ms、RTF 0.204。原生文本区显示完整结果，底栏更新为已停止，暂停与立即停止禁用。界面属性返回 toolbar=none、fullSizeContentView=true、titlebarTransparent=true、cornerRadius=10、renderer=AppKit，玻璃会话栏与悬浮窗均为 NSGlassEffectView。穿透/恢复属性及不抢焦点检查通过。`build/mac-music-runtime.log` 无 AXTree 或约束错误。此轮仅修改 Swift UI，Dart 测试沿用下节已通过的 31 项结果。

当前 DMG `dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`：9,396,036 字节，SHA256 `0d48d8cc513f400e9538d9a726aa643956f8ffca67918abe66a6e742668f9294`。清单记录源码 9cc2ca9、构建时无未提交源码；ad-hoc 签名，未公证。未覆盖此前安装副本。

完整 VoiceOver、系统减少透明度、旧版系统回退和多屏仍未实机验收；麦克风和真实在线 API 未测试。

## 完整 AppKit 重构验收（2026-10-07，原生首版历史记录）

本节包数据属于此前原生首版，当前可下载包见上节。

`codex/mac-liquid-glass` 的 `d41f113` 将六个可见页面全部改为 AppKit，使用原生 NSSplitViewController、NSToolbar、表单、NSTextView、NSAlert 与文件 Sheet。Flutter Engine 无视图运行，只承载共享业务；旧的 chrome 协调器已移除。

最终 Dart 分析无问题，**31 项测试通过，1 项可选 FFI 跳过**。新增验证配置修改保留其它路径和设置、捕获期间锁定输入与服务、拒绝未知配置/操作、界面状态不包含 PCM/凭据、测试模式清空临时字幕不删除已保存历史。保留的 Flutter 明暗/缩放组件测试只代表备用界面回归；原生 UI 使用运行包另行检查。

实际 GUI 验证六页原生辅助功能内容与 ⌘1–6 切换、深浅外观、系统焦点环、草稿跨页保留与保存回调；模型选择为 NSOpenPanel Sheet。历史搜索 `fellow` 只显示对应段；NSSavePanel 将两条确认字幕写入 build/mac-native-ui-export.txt，与完整识别输出相符。清空确认选择取消后字幕保持。旧版 Flutter 内容区 AXTree 更新错误在完整原生页面切换中不再复现；未开启 VoiceOver 朗读或修改系统权限。

静默真实 Whisper tiny WAV 验收使用原生 AppKit 文本区与 NSPanel，不播放、不采集麦克风、不联网翻译。首轮 build/mac-native-runtime.json：110 帧、11 秒、2 条 final、0 丢弃，结束后 running=false；最后 3.5 秒窗口推理 1437 ms、RTF 0.411。它验证端到端识别与界面状态，不能代替采集设备或准确率验收。

最终包 `dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`：9,393,471 字节，SHA256 `a3bedc4b345edf24bc2712e1951c490e52e5aaff17812e929bd97c2c0e03ce1b`。清单记录源码 d41f113、构建时无未提交源码；ad-hoc 签名、未公证。先前安装副本未覆盖。

最终包复验 build/mac-native-final.json：status=ok，同样收到 110 帧、11 秒、2 条 final，停止后原生 running=false；最后 3.5 秒窗口推理 656 ms、RTF 0.188。界面返回 renderer=AppKit、NSToolbar、NSSplitViewController，控制条与悬浮窗均为 NSGlassEffectView。穿透开关和原生恢复入口的属性检查通过；悬浮窗 canBecomeKey=false。GUI 又检查六页切换、离线服务页、暂停按钮禁用、⌘F 原生查找栏、⌘L 隐藏悬浮窗；原生系统控件及 Sheet 采用中文本地化。运行日志没有 AXTree 或约束错误。

完整 VoiceOver、减少透明度开关、旧版系统回退、多屏及全屏覆盖未实机验收；麦克风及在线 API 继续保持此前边界。

## 早期导航重构记录（2026-10-07，已被完整重构替代）

Git 基线保留在 main；codex/mac-liquid-glass 与 codex/windows-material3 从同一基线分别开发。两分支的 Dart 分析均无问题，测试各为 **26 项通过，1 项可选 FFI 跳过**，新增覆盖明暗配色、125% 文字缩放和最小桌面布局。Windows Material 3 的 NavigationRail 在宽窄窗口切换展开状态；Windows 原生安装产物仍未构建。

macOS 测试包 dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg 已构建，采用 ad-hoc 签名。实际运行的导航区为 NSGlassEffectView，224×618 点、6 个原生按钮；工具区为 NSGlassEffectView，636×78 点、2 个原生按钮。它们由 AppKit 窗口承载，FlutterViewController 负责实色内容区。GUI 截图检查了实际玻璃与页面绘制；模型、外观导航和悬浮窗按钮实际动作已验证。

最终静音 WAV 验收 build/mac-glass-runtime.json：status=ok，110 帧、11 秒输入、2 条 final，结束后原生 running=false；最后 3.5 秒窗口推理 587 ms、RTF 0.168。没有播放音频、麦克风采集或联网翻译。原始采集权限验收继续沿用下文记录。

辅助功能限制：原生导航与按钮的可访问状态可读。开启本机辅助功能自动化后，Flutter 内容区部分页面切换出现 AXTree 更新错误；未宣称 VoiceOver 验收通过，详见 docs/ui-variant.md。未修改系统权限或 Flutter 引擎来绕过该问题。13.3–15 的视觉效果回退和系统降低透明度路径已实现，尚未在对应环境实机验收。

## 测试环境

- Apple M2、16 GiB 内存、arm64；macOS 27.2 beta（26B5091g）。
- Flutter 3.47.6 / Dart 3.13.5；Swift 6.2、AppleClang 17；CLT SDK，未安装完整 Xcode。
- CMake 4.4.4、Ninja 1.13.2；whisper.cpp v1.8.1，CPU + Accelerate，未启用 Metal 推理。
- tiny 多语言 GGML，77,691,713 字节；来源与 SHA256 见 assets/models.json。模型不随安装包分发。

## 自动化结果

`dart analyze lib test`：无问题。`dart analyze scripts/artifact_manifest.dart`：无问题。

基线 `flutter test --reporter expanded`：**24 项通过，1 项可选真实 FFI 测试跳过**；本界面分支为 26 项通过。普通测试不使用 Key、不访问翻译服务、不产生 API 费用。覆盖：

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

每次构建生成 `.sha256` 和 `.artifact.json`，记录文件、平台、架构、版本、实际 SHA256、签名类型、构建时间和源码 revision。基线早期构建没有 Git commit；界面分支构建已记录实际提交。当前文件以 dist 内的清单为准。

构建命令与使用方法见 README.md。macOS 实际交付走 scripts/build_macos.sh 的 CLT 原生宿主；仓库 macos/ 的 Flutter Xcode scaffold 尚未集成桥接，不应直接用 `flutter run -d macos` 声称完整功能。Windows scripts/build_windows.ps1 需要 Windows + VS2022/Windows SDK + Inno Setup；待该环境中运行及验证。

本次最终 DMG：10,924,497 字节，SHA256 `1331b1160a8f494d4e19060f803b620979dc0eb09e22aec4f8d21bcaa4daaa67`。已安装位置 `$HOME/Applications/LumaCaption.app`。采用 ad-hoc 的开发更新可能改变 TCC 认可的代码身份；如更新后系统要求重新授权，请对当前安装副本授权。
