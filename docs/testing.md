# LumaCaption 0.1.0 验收记录

更新：2026-10-07。这里区分源码实现、模拟协议测试、真实模型运行和设备验收。

## Metal 与词级稳定预览（2026-10-07，0.1.0+6 历史记录）

源码实现 `6ca9d6f`，包版本 `0.1.0+6`，已安装到 `/Applications/LumaCaption.app`。macOS 使用 Metal，GPU 内核源码嵌入本地 dylib，不依赖工作目录、外置资源或用户安装 Metal 编译工具；初始化失败时保留 CPU 回退。后端名称依据 whisper.cpp 实际初始化记录，不能仅根据构建开关宣称 GPU 正在使用。Dart/native ABI 同步升级为 2；Windows 仍为 CPU。

本地文本翻译模式第 2 秒开始预览，以推理耗时的移动平均调整后续 1–3 秒预览间隔；待处理预览只保留最新一份，最多保留两份最终窗口，最终识别优先。连续两次识别按词比较，忽略一般标点和大小写，保留词内撇号区别并把末尾一个词留作可修订；短前缀继续等待，最终识别不受该预览门槛限制。下一窗口只使用已确认的短前文，重复识别同一增长窗口不回灌自己的预览。最长 8 秒上下文、600 ms 静音收尾、重叠去重与预览不进入确认导出的语义保持。

完整 `dart analyze` 无问题，**103 项测试通过、1 项可选 FFI 跳过**。新增测试覆盖自适应节奏、最新预览和最终队列优先、词级标点/大小写/中文/撇号、确认上下文的代次及长度边界、紧急停止在原生 stop 返回之前失效旧结果、等旧 worker 完成后重新开始，以及数值化逐次推理耗时。真实 tiny FFI 已验证 Metal、显式 prompt、预览、立即取消与随后恢复；仅拷贝 dylib 到工作目录之外也能推理。Swift 编译、arm64 打包与安装副本深度签名验证通过。

已安装 dylib 的真实静音原生测试，multilingual base 与 small 各一次暖机、三次暖态，均实际使用 Metal。一次性处理公开 11 秒英语样本，暖态推理中位数分别为 180.376 ms（177.910–181.646）和 452.374 ms（452.265–478.826），八次最终原文该 22 词参考 WER=0%。这些只计本地原生推理，不包含音频积累、原文稳定或翻译；GPU 缓存已热，不能据此宣称首次冷启动成本。详见 [Metal 报告](whisper-metal-benchmark.md)。

真实在线静音文件对照按 base1、small1、base2、small2、base3、small3 顺序各三轮，使用同一公开 11 秒英语样本、110 个 100 ms 帧、`qwen-mt-flash` 英语→中文。六轮均 status=ok、Metal、零丢弃、两条确认原文与译文，最终该 22 词参考 WER=0%。首个可修订译文中位数 base 3.336 秒（3.327–3.344）、small 3.611 秒（3.565–3.641）；首个确认译文分别为 8.539 秒（8.498–8.558）和 8.815 秒（8.770–8.827）。EOF 后最后确认译文分别为 0.433 秒（0.396–0.476）和 0.688 秒（0.650–0.746）。时间从音频开始算，不含像素绘制，不是点击开始或每词固定落后时间；只有一个干净短样本，不声称总体准确率。

六轮共记录 36 次 MT 请求，全部完成；请求开始到首个译文增量的中位数 191.2 ms（159.4–227.6）。该耗时含客户端、网络和服务工作，不能解释为纯 MT 模型耗时或 TCP 复用证明。本次主要等待发生在首个 MT 请求开始之前，原文积累和两次识别前缀一致仍需时间。

首轮在音频输入前曾停在系统钥匙串读取已有凭据。被动进程采样确认主线程等待 `SecItemCopyMatching`，不是 Whisper 推理卡住；测试入口 `loadingModel` 标签不能代表实际阻塞阶段。安全提示解除后测试完成，完整保留该轮模型准备 7556 ms、准备 1672408.838 ms（约 27.9 分钟），与音频开始后的指标分列。入口 `modelLoadMs` 包含权重校验和模型加载，不是纯 Metal 初始化；base 三轮中位数 1331 ms（1276–7556）、small 为 4294 ms（4186–4485）。其它五轮服务准备 7.504–10.620 ms。电脑控制工具没有操作被禁用的 SecurityAgent 安全窗口，没有读取或记录凭据值。完整逐次识别、HTTP 请求与字幕数值见 [在线汇总](benchmarks/whisper-metal-2026-10-07.json)；原生独立推理与在线口径分开报告。

原生辅助功能实际观察到 base 的“预览 · 可修订”与早期译文，small 与 base 的完整两条双语字幕均变为“已确认”，底栏恢复“已停止”、开始按钮可用。测试不保存偏好或历史；完全退出测试进程并重新打开普通应用后，GUI 确认 text＋small、输入电平 0、准备就绪、悬浮字幕关闭、未启动采集。继续工作之初 GUI 另有系统采集授权拒绝提示，该提示不影响文件对照；本轮没有为了复验它而请求采集授权或调用真实系统录音。

当前 DMG `dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`：11,275,192 字节，SHA256 `a10273ff2b1e75f8a5b775e53e711b3cf59aebc82f7400052eb01805fa43c59e`。清单记录源码 6ca9d6f、构建时无未提交源码；ad-hoc 签名，未公证。此前安装副本保存在 `build/installed-backup/LumaCaption-before-0.1.0+6.app`。本轮不播放音频、不使用扬声器、AirPods 或麦克风，也不启动系统声音采集；文件测试不能替代本包 TCC 采集复验。

## 本地稳定预览翻译（2026-10-07，0.1.0+5 历史记录）

源码实现 `eee7aad`，包版本 `0.1.0+5`，安装在 `/Applications/LumaCaption.app`。本地识别＋文本翻译提前提交连续两次识别一致的原文前缀，最终原文确认后校正译文。取消文本队列 350 ms 等待，复用 HTTP client，并新增数值化请求阶段计时；保留 8 秒最终识别上下文、紧凑边栏和系统窗口按钮。

完整 Dart 分析无问题，**75 项测试通过、1 项可选 FFI 跳过**。新增测试覆盖原文改写撤回、空 final 撤回、源/译 revision 分离、缓存预览转确认、预览不进入历史与导出、队列替换和过时回调、非协作取消、SSE 单请求取消/超时不影响其它请求、JSON/SSE/429 本地连接复用和数值阶段计时。最终 Swift 编译、arm64 DMG 构建及安装副本深度签名验证通过。

真实静音文件测试：Whisper tiny＋`qwen-mt-flash` 三轮首个可修订译文中位数 **3.609 秒**（3.583–4.046），旧版确认原文路线为 9.010 秒；首个确认译文仍为 8.803 秒。15 次记录的 MT 请求首增量中位数 200.6 ms（177.5–619.1）。用户普通应用当前选择 small，另补测一轮：首译 9.892 秒，首个 MT 请求 9.655 秒，首次 MT 等待约 237 ms。四轮均 status=ok、110 帧、11 秒、两条确认原文与译文、零丢弃，最终原文该 22 词样本 WER=0%。首轮 tiny 服务准备额外用了 7.070 秒，保留异常，不能把 3.609 秒说成点击开始后的等待。完整结果和两条路线不足、替代服务见 [预览策略报告](whisper-mt-preview-benchmark.md)。

原生辅助功能实际读到“预览 · 可修订”及提前译文，随后两条完整双语字幕均为“已确认”，底栏恢复已停止、开始可用。测试不保存偏好或历史；恢复普通应用后验证用户所选 small 与文本翻译模式保持。未播放声音、使用扬声器、AirPods、麦克风或启动系统音频采集；本包 TCC 状态未用实际采集复验。

当前 DMG `dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`：11,118,912 字节，SHA256 `e69d842ca007daeb722986a36f8dbe1f50f7c35bf4ce4c311379f5d22655fdb7`。清单记录源码 eee7aad、构建时无未提交源码；ad-hoc 签名，未公证。此前安装副本保存在 `build/installed-backup/LumaCaption-before-0.1.0+5.app`。

## 紧凑边栏恢复（2026-10-07，0.1.0+4 历史记录）

当前源码 `cee731a`，包版本 `0.1.0+4`，安装在 `/Applications/LumaCaption.app`。用户明确希望紫色共享提示位于三个窗口按钮右侧，且接受无法控制系统位置时保留遮挡。当前公开 AppKit 接口未找到调整该系统提示位置的控制；本轮移除内容区复制的窗口按钮和为其预留的额外顶部空间，恢复系统窗口按钮以及 `e83a5e6` 的紧凑边栏布局。112×20 pt、10 pt 圆角的输入电平条保持。

Swift 编译、完整 arm64 打包及安装副本深度签名验证通过。普通 GUI 已检查原生三个窗口按钮的辅助功能属性、品牌和导航恢复顶部位置、底栏布局和未开始采集的状态。界面截图中品牌与导航相对 0.1.0+3 上移约 32 pt，红黄绿恢复至系统标题栏位置。本轮没有修改 Dart 识别/翻译业务；沿用上一版 53 项测试通过、1 项可选 FFI 跳过的结果，没有声称重新运行。本轮未启动采集、播放音频、使用 AirPods 或麦克风、调用在线 API；此前版本的系统采集授权结果见下文，不能替代本轮包的权限复验。

当前 DMG `dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`：11,109,433 字节，SHA256 `324cad7675bcc4465e01a901705f73c9e3836442ca9ab27d3c7238ee2e72730f`。清单记录源码 cee731a、构建时无未提交源码；ad-hoc 签名，未公证。此前安装副本保存在 `build/installed-backup/LumaCaption-before-0.1.0+4.app`。

## Qwen 3.8、Whisper＋MT 与边栏内窗口按钮（2026-10-07，0.1.0+3 历史记录）

当前源码 `04b3b58`，包版本 `0.1.0+3`，安装在 `/Applications/LumaCaption.app`。macOS 27.2 beta（26B5101f），Apple M2、16 GiB 内存；其它工具链同下文。完整 Dart 分析无问题，**53 项测试通过、1 项可选 FFI 跳过**；最终 Swift 编译、arm64 DMG 构建和安装副本深度签名验证通过。

`qwen3.8-livetranslate-flash-realtime` 使用 Workspace 专属 WebSocket 接口，16 kHz PCM 增量上传，配置为仅文字输出。已接入新的 session/audio 配置和 delta/done 协议，保留旧 3.5 配置兼容。本地 Whisper＋`qwen-mt-flash` 只上传确认原文，通过 SSE 增量显示译文；未完成译文不进入确认结果导出。两种 Endpoint 的凭据实际存入并从系统钥匙串读取，普通设置不含密钥。单元及本地模拟服务覆盖 3.8 协议、流式文本、Unicode、结束/中断、并发结果顺序和过时回调过滤，不将模拟测试视为真实服务验证。

真实在线验收以 whisper.cpp 的公开 `samples/jfk.wav` 为输入，英语→中文，11 秒、110 个 100 ms 帧，按实时节奏静默送入业务流程。两条路径各三轮，六轮均 status=ok、零帧丢弃。实时模型首段译文中位数 3.277 秒（3.171–3.414），Whisper tiny＋MT 为 9.010 秒（8.937–9.065）。EOF 后最终译文中位数分别为 0.875 秒和 0.684 秒；文本第三轮收尾为 12.446 秒，保留此异常值，现有计时不能确定服务端、网络或客户端原因。计时指控制器收到字幕事件，不含像素绘制，模型加载另计。两者六轮最终原文对同一 22 词参考均为 WER 0%，中文四项核心语义均保留；这不是总体准确率结论。完整逐轮证据、译文与限制见 [实测报告](qwen38-whisper-mt-benchmark.md) 和 [汇总 JSON](benchmarks/qwen38-whisper-mt-2026-10-07.json)。没有使用扬声器、AirPods、麦克风或系统声音输入进行在线样本测试。

窗口按钮使用公开 AppKit 工厂创建，位于边栏内容安全区、系统共享区域下方，原有标题栏按钮隐藏，系统紫色隐私入口保持不变。真实 GUI 验证三按钮辅助功能语义，绿色进入/退出全屏，黄色最小化后从窗口菜单恢复，红色关闭后主窗口隐藏。112×20 pt 电平控件背景和绿色填充统一 10 pt 圆角并裁剪；最小窗口底栏布局检查通过。测试报告返回 persistentWindowControls=3、windowControlsLocation=sidebarSafeArea、inputMeterWidth=112、toolbar=systemSharingArea。

16:29:25 从当前安装副本正常 GUI、离线模式启动系统采集，收到真实 TCC -3801，设置页确认运行路径 `/Applications/LumaCaption.app`。完全退出后，用户重新添加当前副本并授权；16:31:10 正常 GUI 再次开始，状态变为「正在聆听」，设置页显示系统声音「已允许」。实际采集截图中三个彩色窗口按钮完整可见，输入电平约 33%，112 pt 电平背景及绿色填充均为圆角。此次窗口内未出现紫色共享入口，没有修改该系统入口，也不声称完成二者同时出现的视觉验收。正常停止并等待识别收尾后，16:32:14 状态恢复「已停止」，丢弃帧 0，开始按钮重新可用；刷新权限仍为已允许。未读取或修改 TCC 数据库，未播放音频、使用 AirPods、请求麦克风或在该采集复验中联网。临时字幕未写历史；随后重开应用，选定千问实时模式并保持未采集。

当前 DMG `dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`：11,120,773 字节，SHA256 `6e5fa019805808d6406b971a4fb004b030c69591766b548369b35b42dc890c3f`。清单记录源码 04b3b58、构建时无未提交源码；ad-hoc 签名，未公证。此前安装副本保存在 `build/installed-backup/LumaCaption-before-0.1.0+3.app`。

## 权限诊断、窗口控制区与品牌图标（2026-10-07，0.1.0+2 历史记录）

当前源码 `e83a5e6`，包版本 `0.1.0+2`。系统声音开始失败按真实 ScreenCaptureKit 错误分类：-3801 为系统授权拒绝，-3818 为音频流启动失败；麦克风拒绝独立处理。权限查询不把 CG 预检失败直接认定为拒绝，真实启动后刷新状态。失败后底栏恢复为「无法开始字幕」并允许重试。设置页显示正在运行的应用路径，诊断保留原生错误域和代码，不记录路径。

当前安装副本此前位于 `/Applications/LumaCaption.app`，另有用户 Applications 与工作区 dist 同名副本，均为 ad-hoc 签名但代码身份不同。用户截图中授权开关已开启，旧安装副本完全退出、重新打开后仍收到真实 TCC -3801；新包安装到同一路径后也收到 -3801。旧包保存在 `build/installed-backup/LumaCaption-before-0.1.0+2.app`。当前机器没有可用正式签名身份；同名副本与版本变化造成授权不匹配是有依据的推测，未读取或修改 TCC 数据库来确认。用户移除旧授权条目并重新添加当前 `/Applications/LumaCaption.app` 后，当前包正常 GUI 采集启动与停止通过。

重新授权后的静默 GUI 复验：15:49:25 开始 `offline · system`，原生界面变为「正在聆听」，设置页显示系统声音「已允许」及 `/Applications/LumaCaption.app`；15:49:54 正常停止，状态恢复「已停止」，暂停与立即停止禁用、开始按钮重新可用。诊断显示丢弃音频帧 0，无 TCC 拒绝；停止后点击刷新状态仍为「已允许」。此次约 29 秒只验证授权、采集启动和停止，没有播放音频、使用麦克风或联网，也没有有声样本或转写准确率结论。未用 CLI 采集结果代替正常 GUI 验收。

窗口使用透明、没有操作项的 `.unified` NSToolbar，由 AppKit 分配标准窗口控制区域；没有可见标题、侧边栏切换或顶部字幕按钮。边栏恢复 LumaCaption 名称与 24 pt 品牌图标。扁平玻璃字幕气泡与声波图标已转换为 ICNS，并接入 Info.plist、构建脚本和边栏。⌘W 关闭或隐藏入口补齐。GUI 检查品牌、权限与路径说明、底部控制栏和真实字幕内容。系统紫色「窗口共享」入口曾在 AX 中替换红黄绿按钮；它属于 macOS 管理，空工具栏不能保证改变系统的替换行为。

完整 Dart 分析无问题，**35 项测试通过、1 项可选 FFI 跳过**；新增覆盖开始失败后的权限刷新、状态恢复、查询失败不覆盖主要错误与诊断路径脱敏。原生错误分类测试 **4 项通过**，不调用采集或修改系统权限。最终 Swift 编译、arm64 DMG 构建和安装副本深度签名验证通过。

最终包静默真实 WAV 结果 `build/mac-permission-logo-final.json`：status=ok，110 帧、11 秒、2 条 final、0 丢弃；停止后原生采集 running=false。最后 3.5 秒窗口推理 887 ms、RTF 0.254。原生 AppKit 文本区实际显示两条字幕，底栏显示已停止。界面报告 toolbar=windowControlsOnly、toolbarActions=0、fullSizeContentView=true、titlebarTransparent=true、cornerRadius=10；会话栏与悬浮窗为 NSGlassEffectView，不抢焦点与穿透恢复属性通过。运行日志无 AXTree 或约束错误。全程没有播放声音、采集麦克风或调用在线 API；系统声音授权复验见本节上文。

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
