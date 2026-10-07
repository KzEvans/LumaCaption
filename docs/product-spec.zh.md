# LumaCaption：给 Codex 的完整开发提示词

你是一名资深跨平台桌面应用工程师，熟悉 Flutter/Dart、原生音频采集、本地语音识别、实时翻译协议、桌面窗口管理与安装包发布。

请在当前工作目录实际开发一个 macOS 与 Windows 通用的 AI 实时翻译字幕软件，暂定名「LumaCaption」。我要的是可以安装、具有完整图形界面、能够处理真实声音的软件，不是网页原型、伪代码、演示动画或仅有架构说明的项目。

请先阅读已有文件和项目约束；已有代码能够复用时不要推倒重写。无需反复询问非关键设计细节，按以下要求作出合理选择并记录理由。除真实凭据、系统授权、发布签名或确实无法访问的构建环境外，尽量自行推进实现、测试和打包。

一、不可更改的产品目标

1. 同一套主体代码支持 macOS 和 Windows，主要编程语言保持精简。
2. 本地语音转文字采用现有开源模型；用户可以通过 GUI 选择、下载、导入和切换兼容模型，不训练新模型。
3. Windows 提供系统语音识别选项；需要查证公开接口、系统版本和模型可用性，不得伪造“Windows 实时字幕内部模型 API”。
4. 翻译接入第三方 API，默认选择 qwen3.5-livetranslate-flash-realtime，允许配置其他兼容服务。
5. 界面参考 Apple Human Interface Guidelines 和 macOS SwiftUI 应用的视觉、交互习惯，但 Windows 必须能够运行。
6. 交付两端真实安装包、源码、构建脚本、测试结果和使用文档。
7. 系统声音采集、实时字幕、可用的悬浮窗和安装后启动是核心能力，不能只实现麦克风或静态 UI。

二、技术栈与实现边界

以 Flutter + Dart 为主技术栈，让界面、配置、模型管理、网络协议和字幕逻辑共用代码。使用实际可获取的稳定版本并锁定依赖，记录 Flutter、Dart、原生库、Windows SDK 和构建工具版本。

本地识别优先集成 whisper.cpp，通过维护可靠的现有绑定或 dart:ffi 调用。不要为了封装薄薄一层推理逻辑引入 Python 服务、Node 服务或额外常驻后台服务器。

平台专属能力允许使用最小化原生桥接：macOS 使用 Swift/Objective-C，Windows 优先 C++/WinRT。只有确有必要且说明原因时才增加其他语言。不要为了“全部 Dart”而牺牲系统声音采集，也不要把两端写成两套独立业务程序。

优先完成 macOS Apple Silicon arm64 与 Windows x64；评估并记录 macOS Intel、Windows ARM64 的支持情况。可暂以 macOS 13+、Windows 10 22H2+作为基础功能目标，但须验证当前 Flutter 和依赖的实际支持范围。Windows 系统 AI 识别使用更严格的独立版本要求，不影响普通本地识别功能。

不将真正的 SwiftUI 作为 Windows UI 框架。Flutter 的 Cupertino 控件可按需参考，但不要把整套桌面界面做成放大的 iPhone 设置页。

先核实重要接口再实现：
- 千问 3.5 LiveTranslate 的模型 ID、可用地域、认证、会话参数及事件语义。
- Windows 系统语音 API 的 SDK 版本、stable/experimental 状态、打包身份和实时音频输入能力。
- 两端系统音频采集、透明多窗口、鼠标穿透和安装包方案。
把查证日期、官方资料、最小验证结果及限制写入 docs/feasibility.md。查不到或运行不通就明确标注，不能把“文档上有”写成“实机通过”。

三、必须区分的工作模式

模式 A：千问实时音频翻译，作为默认翻译模式。
音频采集 → 音频格式转换 → Qwen LiveTranslate 实时接口 → 译文字幕。
同一音频可以并行进入用户选择的本地识别引擎，产生原文字幕；本地模型未安装时，允许先使用仅译文模式，也允许用户明确开启云端原文识别。

重要：LiveTranslate 的音频翻译路径不是“把本地识别文本发送给普通 chat/completions”。不得用文本冒充音频输入，也不要增加 TTS 来绕过接口类型。

模式 B：本地识别 + 文本翻译。
音频采集 → 本地开源模型或可用的 Windows 系统识别 → 稳定文本片段 → 文本翻译 API → 译文字幕。
为这个模式提供独立的 Qwen-MT 适配器和 OpenAI-compatible 文本翻译适配器，不能将其冒充千问 3.5 LiveTranslate。

模式 C：离线原文字幕。
只使用已安装的本地识别能力；不调用翻译 API、不上传音频或文本。

界面必须清楚展示当前模式、识别引擎、翻译模型，以及“上传音频”“仅上传文本”或“完全本地”的状态。
不要因为原文在本地识别，就声称模式 A 的音频不会上传。
两种在线模式之间切换、连接恢复或回退时，不得未经用户同意改变数据上传范围、服务提供商或计费模式。

四、真实音频采集

支持“系统声音”和“麦克风”两个独立来源，提供设备选择、输入电平、开始、暂停、继续、停止和权限状态。系统声音为主要使用场景，应能翻译浏览器视频、播放器、会议软件和普通游戏输出的声音。

macOS：优先使用 ScreenCaptureKit 获取系统音频，麦克风走合适的原生音频接口；依据实际系统版本处理录音、屏幕与系统音频相关授权。默认不采集、保存或上传屏幕图像；如果框架需要屏幕捕获会话，说明原因并尽量减少不需要的视频开销。

Windows：系统音频使用 WASAPI loopback，麦克风使用合适的录音接口。普通系统混音采集不以用户手动安装虚拟声卡或启用“立体声混音”为默认前提。不要声称 loopback 能绕过 DRM、捕获所有独占输出或任意受保护音频。

先做好单一来源；“系统声音 + 麦克风”混音可后续加入，加入时必须处理时间对齐、重复拾音和声学回声问题，不得只把两路样本相加就称为完善混音。

使用带采样时间信息的有界缓冲；识别和网络发送不能阻塞音频回调。完成真实重采样、声道转换和数值类型转换，不是只改采样率字段。根据各引擎要求分别输出 PCM16 或 float PCM。

处理设备拔插、默认设备切换、权限撤销、休眠唤醒、蓝牙设备变化和采集失败。停止或退出后释放设备、线程、原生对象及后台任务。不要默认回放捕获音频，避免反馈回路。

五、本地识别与模型管理

第一版至少完成一个真实可用的 whisper.cpp 引擎，模型目录优先覆盖 multilingual tiny/base/small，以及经过验证兼容的 medium、large-v3、large-v3-turbo 和量化版本。不要把 .en 模型作为中日韩多语言默认项。

GUI 模型管理需包含：
- 模型名称、语言范围、来源、许可证、文件格式、下载大小和估计内存需求。
- 下载进度、速度、暂停、继续、取消、失败重试、删除与空间检查。
- 下载完成后的可信校验和校验、临时文件原子替换、损坏文件处理。
- 本地模型导入、自定义存储目录、打开模型文件夹和启动前兼容性检查。
- 安装、加载、就绪、错误状态，以及当前使用模型与硬件后端。

下载目录用 manifest 管理，记录 engine、modelId、revision、format、URL、checksum、license 等信息。来源使用上游官方仓库或可追溯发布源；不要编造下载地址、SHA256 或许可证。下载端不支持 Range 时，诚实降级为重新下载，不显示虚假的续传成功。

“自选模型”指用户可以选择受支持引擎的兼容模型，不是任意文件都能推理。拒绝不兼容格式，不执行下载模型附带的任意代码；不将模型权重和可执行插件混为一谈。用户导入且无可信来源哈希的文件，不得显示“来源已验证”。

Apple Silicon 优先评估 Metal，Windows 先确保 CPU 可用；Vulkan/CUDA 等加速只有在编译、运行及依赖打包验证后才展示。检测实际启用的后端，不能只根据 GPU 型号显示“已加速”。

模型推理放在独立 isolate/工作线程，处理 FFI 内存生命周期、取消、超时和模型切换。Whisper 的滑窗处理不等于模型原生无限流式识别，需要实现音频分段、重叠区去重和最终文本确认。

首次启动不擅自下载大模型。引导用户选择模型；普通配置可建议 multilingual base 或 small，但以实际测试为准。

六、Windows 系统识别选项

把以下三类能力分清楚：
A. Windows AI Speech Recognition 等公开的系统 AI 识别 API。
B. Windows 传统 SpeechRecognition API。
C. Windows“实时字幕”应用及其内部实现。

优先调查并集成 A，不能把 A、B、C 当作完全相同的模型或能力。界面推荐标注“Windows 系统语音识别”，而不是未经证实的“直接调用实时字幕同款模型”。

查证 Microsoft.Windows.AI.Speech 下 SpeechRecognitionModel 等实际接口；按可用 SDK 实现 GetReadyState、EnsureReadyAsync、模型创建、识别和释放。系统模型下载必须通过官方管理机制，并在需要下载前征得用户同意。

现有官方资料涉及 Windows 11 新版本、Windows App SDK、MSIX 身份和 systemAIModels 等要求；部分 API 参考带 experimental 标记。必须用当前实际安装的 SDK 做最小编译与运行验证，不能只抄一段示例并宣称支持所有 Windows 电脑。

重点验证能否持续接收我们捕获的系统音频。对于 FromStream、ForProvider 或其他提供音频的方法，要验证输入格式、时间行为和生命周期；“能读 WAV 文件”不等于“支持持续系统音频”。接口只返回句级最终结果时，不伪造 token 级中间结果。

将系统识别隔离为可选能力，并提供 available、modelMissing、unsupportedOS、unsupportedHardware、requiresPackageIdentity、experimental、initializationFailed 等诊断状态。必要时使用独立构建 flavor 或延迟加载，防止新 SDK/DLL 使基础版在较旧系统启动失败。

不支持时在 UI 显示原因，并允许回退到已安装的 whisper.cpp 模型；未安装模型则引导下载。不能静默上传音频来冒充本地回退。

如果官方能力仅能作为实验功能交付，应明确标记且保持基础版稳定。不要读取私有模型目录、注入实时字幕进程、逆向私有接口或把 OCR/UI 抓取当作正式识别引擎。无法完成系统识别时，将其列为明确的未完成项，而不是把空接口记作已完成。

七、默认千问实时翻译适配器

固定默认模型 ID 为 qwen3.5-livetranslate-flash-realtime；支持用户修改 modelId，但不要擅自更换默认模型。默认只要文本字幕，不生成译音、不启用音色克隆、不上传视频画面。

第一版可采用直接 WebSocket 协议，避免引入额外 Python/Java 服务。遵照官方协议实现，而不是假设所有名为 Realtime 的接口都兼容。

配置项至少包括 API Key、地域、Workspace ID、WebSocket Endpoint、modelId、源语言、目标语言、代理和超时。界面可默认目标语言为简体中文，源语言按该接口真实支持方式设置为自动检测或指定语言。

当前应核实的地址模板：
北京：wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime
新加坡：wss://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/api-ws/v1/realtime
通过 model 查询参数指定模型。认证和地域必须匹配；模板占位符未填写时应阻止连接。保留完整 Endpoint 自定义能力，不把服务地址写死。

实现完整生命周期：
连接和认证 → 确认会话 → session.update → 确认配置 → 持续发送音频 → 接收字幕 → 正常结束会话 → 释放资源。

按 3.5 模型自己的协议核实并设置 modalities=["text"]、音频格式、采样率及 translation.language。原始音频按要求转换为真实的单声道、16 kHz、16-bit PCM，再通过 input_audio_buffer.append 等对应事件发送。分块粒度根据协议与测量结果确定，不能每帧都重新建立连接。

重点处理 session.created/session.updated、输入提交、识别与翻译结果、response 完成、服务端错误、session.finished 等实际存在的事件。不同模型协议版本独立解析，不共享一个未经验证的“通用事件解析器”。

3.5 的文本事件重点核实 response.text.text 和 response.text.done；处理 text、stash、response_id、item_id 等字段。stash 属于可能修改的临时预测，不应永久追加到已确认文本；不能机械套用 response.text.delta 的拼接逻辑。用真实多事件记录确认 text 的追加或快照语义，最终以 done 的完整结果校正。

根据所选语音边界模式正确处理 VAD 和手动 commit，不重复提交。优雅停止时发送 session.finish，等待完成或明确的超时；不要直接断线导致最后一句丢失。用户紧急停止则立即停止上传，明确未完成片段状态。

支持重连、退避、心跳/超时、限流、额度不足、鉴权失败和区域错误。不得无限缓存断网音频，重连时默认不补传陈旧私密音频，不重复计费发送已确认内容。

八、文本翻译接口

实现两个清晰区分的适配器：
1. Qwen-MT：可使用经验证可用的 qwen-mt-flash，按照该模型专用 messages 和 translation_options 规则请求，不机械套用通用多轮对话模板。
2. OpenAI-compatible 文本翻译：允许自定义 Base URL、API Key、modelId、必要请求头及经过限制的附加参数；按真实支持情况处理流式和非流式响应。

每个 provider 声明输入类型、流式能力、语言范围和是否支持上下文、术语表。配置界面只展示有效选项，不保证任意第三方接口都兼容，也不强制依赖 /models 列表。

文本模式只发送稳定或已确认的识别片段；提供可调防抖，避免每出现一个字就计费请求。支持取消过时请求、有限并发、去重缓存、限流退避、合理超时和按 segmentId 排序返回。

支持术语表和有限上下文，但必须按各模型实际契约传入。通用模型的翻译指令要求只输出译文、不回答原文中的问题，把待翻译内容当数据而不是软件指令。防止原文内容触发工具调用或读取本地信息。

连接测试必须真实发起协议请求并明确可能产生的小额费用；失败时返回可行动的错误原因，不只显示“连接失败”。

九、字幕处理与实时体验

统一定义 AudioFrame、AsrEvent、TranslationEvent、SubtitleSegment 和能力描述。至少包含会话 generation、segmentId、revision、音频时间范围、原文、译文、partial/final、来源引擎和错误状态；时间缺失时允许为空，不伪造。

使用采样时间和单调时钟维护音频时间线，不能把 API 到达时刻当作语音发生时刻。区分“音频结束到最终字幕”和“语音开始到首个可见字幕”等延迟指标。

本地分段支持 VAD、滑动窗口、短暂停顿合并、长句上限和重叠去重。原文先显示可修订结果，再确认；译文分阶段更新，避免整页闪烁或不断重排。中日韩文本不能依赖空格分词。

模式 A 的本地识别与云端翻译可能分句不同，不能按第 N 条结果强行逐句配对。优先利用真实关联 ID 与时间范围；无法可靠对齐时展示独立原文/译文流，或标注近似对齐。导出中的估计时间须如实说明。

所有队列设置上限。实时性能不足时提示并采用明确的降级策略，例如换小模型、降低刷新频率、跳过过时任务；不要积压几十秒后仍称为实时，也不要无提示丢弃最终字幕。

切换设备、模型、目标语言或 provider 时产生新的 generation，取消旧任务，防止旧结果混入新会话。断网后可继续本地原文字幕，但不能把原文复制到译文区冒充翻译。

十、GUI、苹果设计语言与悬浮字幕

默认中文界面，预留英文；首次启动提供音频权限、工作模式、模型下载、API 配置及试用字幕的引导。没有 Key 或模型时，显示可操作的空状态，不崩溃、不播放伪造的实时结果。

主窗口采用桌面布局：左侧轻量导航，右侧工作区，顶部简洁工具栏。页面包括实时字幕、模型管理、翻译服务、字幕外观、历史与导出、设置和诊断。

视觉使用留白、清晰层次、克制的强调色、圆角、细分隔线和轻阴影；支持明暗主题、缩放、键盘操作和减少动态效果。磨砂/半透明只在平台实际支持且性能合适时启用，提供不透明回退。不要用背景模糊假装已经实现桌面原生透明窗口。

macOS 尊重系统标题栏、窗口按钮、菜单和快捷键；Windows 保留合理的本地窗口操作。字体使用操作系统已有字体及合法备用字体，不打包 Apple 专有字体或不适合跨平台分发的图标资产。

悬浮字幕必须是真实独立桌面窗口，不是主界面里画出的预览卡片。至少支持：
置顶、拖动、调整大小、背景透明度、字体大小、原文/译文/双语显示、多屏位置记忆、交互模式与鼠标穿透模式。

鼠标穿透必须有恢复入口，如托盘菜单或可配置全局快捷键；不能让窗口变得永远无法操作。实现不抢焦点的显示策略，字幕更新不能打断正在操作的播放器或游戏。

处理 DPI 缩放、显示器拔插、窗口离屏恢复与多窗口资源释放。全屏和 Spaces 行为按系统实测记录；不承诺盖住所有独占全屏游戏，不使用进程注入或内核手段实现覆盖。

提供托盘/菜单栏入口、开始/停止/隐藏字幕操作，以及可配置快捷键。明确关闭主窗口与退出程序的区别；退出必须结束录音、上传和推理。

十一、配置、隐私、历史与导出

API Key 使用经过验证的系统安全存储：macOS Keychain；Windows Credential Manager/DPAPI 等合适实现。普通设置文件只存引用或非敏感数据；导出配置、日志、崩溃报告和 CI 输出不能包含 Key。

允许用户修改服务地址，但修改 host 后不得把已有凭据自动发送到新主机；需要明确重新确认。TLS 校验保持开启，明文 HTTP/WS 只可在明确启用的本地开发场景使用。

默认不保存原始音频，不开启遥测，不自动持久化敏感字幕。会话历史先保留在内存，持久化由用户开启；支持清空历史和删除模型。诊断日志默认只记录状态和性能，不记录原始音频、全文字幕或认证头。

提供 TXT、SRT、VTT 导出，支持原文、译文、双语。优先导出 final 字幕，处理跨行文本、UTF-8、时间单调性和重叠片段。字幕内容按纯文本显示，不执行其中的 HTML、脚本或链接操作。

十二、工程结构与测试

结构保持清楚但不过度设计，可参考：
lib/app/
lib/features/{live,models,providers,appearance,history,settings}/
lib/core/{audio,asr,translation,subtitles,storage,diagnostics}/
packages/native_audio/
packages/whisper_engine/
macos/
windows/
test/
integration_test/
scripts/
docs/
.github/workflows/

将音频采集、模型管理、识别、翻译、字幕状态机、窗口管理和存储隔离；UI 不直接处理原生指针、模型文件解析或供应商原始事件。选择一种状态管理方式，不混用多个框架。

必须有自动化测试，重点覆盖重采样与缓冲、模型下载中断与校验、Whisper 重叠去重、千问 text/stash/done 修订、文本翻译乱序、会话切换、断线与收尾、配置脱敏和 SRT/VTT 导出。

提供可注入音频文件和模拟服务端事件的测试入口，让没有麦克风或 Key 的 CI 也能验证逻辑。Mock 只能存在于测试或明确标识的演示模式，不能悄悄替代生产识别和翻译。

至少提供一段许可证明确的短音频测试样本，或在仓库内说明用户如何提供测试文件。真实 API 联调通过显式开关和环境变量启用，普通测试不产生费用。

执行静态分析、单元测试和当前可用平台的构建。真实平台验收包含系统声音、麦克风、悬浮窗、键盘/鼠标穿透恢复、权限拒绝、网络故障及安装后启动。CI 能编译不等于声音采集已经实机通过。

性能目标不写死成不可信承诺：在记录的硬件、模型、语言与网络条件下，优先争取本地原文较快出现、在线译文达到数秒级体验。记录首字/最终字幕延迟、RTF、峰值内存、队列长度和丢帧情况；未达到目标时说明瓶颈，不伪造测试数字。

十三、打包和交付

不要将 flutter build 产生的裸目录或单独一个 exe 当作完整安装交付。

macOS：生成可安装的 .dmg，内含完整 .app、运行时资源和原生库。优先 arm64；Intel 或 Universal 仅在所有依赖对应架构都构建和验证后交付。配置麦克风/捕获权限说明、必要 entitlements、Hardened Runtime 与签名流程。

Windows：基础版生成真正的安装程序，如 Inno Setup .exe，正确包含 Flutter engine、资源、原生 DLL 和必要运行库，支持快捷方式与卸载。Windows 系统 AI 识别需要打包身份时，另外提供符合实际要求的 MSIX 版本及相应 capability 配置；不能假设裸 exe 天然拥有 MSIX 身份。

终端用户不需要安装 Flutter、Dart、Python、Node、Visual Studio 或编译工具。模型权重默认首次使用时按需下载，不塞入数 GB 默认安装包；程序必需的原生运行库应随应用发布或通过明确的安装依赖处理。

提供构建脚本及双平台 CI：macOS 环境生成 macOS 包，Windows 环境生成 Windows 包。固定可用 runner/工具链版本，上传构建产物和 SHA256。实际运行环境只能构建一端时，如实列出另一端尚未构建，不把 CI YAML 当作已生成的安装包。

签名与安装分开报告：没有 Apple Developer ID 或 Windows 发布证书时，仍尽量完成可构建的测试产物和签名脚本，但不得宣称已经公证、已受系统信任或不会出现安全警告。测试用自签 MSIX 的信任步骤要明确，不能自动修改用户证书信任；不能要求关闭系统安全保护作为默认安装方案。

发布证书、私钥、API Key 不进入源码或发布包。不未经授权发布软件、上传私密数据或执行有费用的服务部署。

十四、实施顺序与验收

请按能运行的纵向切片推进，不要先花大量时间做完整设置页，再发现音频或原生库无法使用。

阶段 0：核实协议和平台边界，做音频采集、whisper.cpp FFI、透明多窗口以及 Windows 系统识别的最小验证；记录成功与阻塞。
阶段 1：打通真实音频 → 一个本地模型 → 原文字幕 → 独立悬浮窗，完成可安装的基础包验证。
阶段 2：实现默认 Qwen 3.5 实时音频翻译、配置页、流式修订、正常结束和错误恢复。
阶段 3：完成模型管理、文本翻译模式、Windows 系统识别可用路径、隐私与导出。
阶段 4：完善视觉、测试、双平台安装包、签名脚本和文档。

每阶段执行实际验证后继续，不只输出计划就停止。遇到缺少 Key、签名或另一平台环境时，继续完成不依赖这些条件的工作；把未做的真实联调单独列出。

最终验收至少确认：
- 安装后可启动真实 GUI，首次配置过程可完成。
- 系统声音和麦克风均有明确的实现与测试状态。
- 至少一个本地模型能从 GUI 下载、校验、加载并产生真实识别结果。
- 默认 Qwen 3.5 LiveTranslate 路径正确；有 Key 时真实联调，没有 Key 时明确“未验证真实服务”。
- 译文增量不会重复堆叠、错配旧会话或丢失正常结束前的最后一句。
- 悬浮窗、托盘和鼠标穿透恢复可操作。
- Windows 系统识别的真实可用范围、实验状态及回退路径明确。
- macOS 与 Windows 安装产物分别有文件、平台、架构、版本、签名状态和 SHA256；缺少的一端明确列为未完成。
- 用户无需开发环境，日志和导出中没有泄露密钥。

最终回复请给出：已实现功能、已运行测试及结果、实际产物路径、双平台构建步骤、需要用户提供的凭据或授权、已知限制与尚未验证项目。
不要把“写了代码”“编译通过”“模拟测试通过”“真实设备测试通过”“已签名可发布”混成同一个完成状态。

核查资料入口（实现时重新核实当前契约）：
Flutter 桌面：https://docs.flutter.dev/platform-integration/desktop
Flutter FFI：https://docs.flutter.dev/platform-integration/bind-native-code
Flutter Windows 打包：https://docs.flutter.dev/platform-integration/windows/building
Flutter macOS 发布：https://docs.flutter.dev/deployment/macos
Apple SwiftUI：https://developer.apple.com/swiftui/
Apple ScreenCaptureKit：https://developer.apple.com/documentation/screencapturekit
Windows WASAPI：https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording
Windows AI Speech：https://learn.microsoft.com/en-us/windows/ai/apis/speech-recognition
Windows SpeechRecognitionModel：https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.ai.speech.speechrecognitionmodel
whisper.cpp：https://github.com/ggml-org/whisper.cpp
Qwen LiveTranslate：https://www.alibabacloud.com/help/en/model-studio/qwen3-5-livetranslate-flash-realtime
Qwen 客户端事件：https://www.alibabacloud.com/help/en/model-studio/live-translator-client-events
Qwen 服务端事件：https://www.alibabacloud.com/help/en/model-studio/live-translator-server-events
Qwen-MT：https://www.alibabacloud.com/help/zh/model-studio/machine-translation

现在开始实际检查工作目录并实施。不要只返回另一份方案。
