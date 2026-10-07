# VAD 断句与末句收尾实验分支

`codex/vad-endpoint-drain` 基于 +7 macOS 分支，当前修正版为 0.1.0+9。公开 Release v0.1.0 仍提供不含 VAD 的 +7；本分支继续作为实验版本。+9 单独输出到 `dist/vad-guard/`，不覆盖 +7 / +8 产物。

## 实现

- Silero v5.1.2 GGML（约 865 KiB）随 macOS 实验包提供，固定官方 revision、大小和 SHA256，MIT 许可证随包。Whisper ASR 权重仍由用户按需下载。
- 独立 CPU VAD worker，单声道 16 kHz，每个新 512 样本窗（32ms）产生概率。`whisper.cpp` v1.8.1 公共 VAD API 每次计算清除循环状态，因此通过最近 1536ms 的对齐音频重放恢复上下文，只消费新增完整窗；这不是原生有状态流式接口。VAD 音频只留在内存。
- 语音概率 ≥0.5 起句、≥0.35 延续，累计至少 256ms 已判语音；连续 **1600ms** 非语音才确认。一句未确认前，短暂低概率只开始等待，不取消延续状态：较轻的 ≥0.35 续音会清除静音计时。确认后才重新要求 ≥0.5 起句。
- 普通静音确认保留最后已判语音窗后 **256ms 真实音频**；明确暂停、正常停止、文件 EOF 或采样缺口则保留整段实际已收到的音频和不足 512 样本的余量，避免低概率尾音被截掉，不补零。保留实际 400ms 前滚、最长 8s 窗和 500ms 重叠。
- 本地离线和文本路线首个预览约 1s，后续基础间隔 500ms，推理过慢时自适应增至最多 3s。最终任务到达时取消同句或更早的在途预览，等待原生调用结束后处理 final；过时的结果和取消错误不进入字幕。
- 暂停/正常停止先排空已经收到的 VAD FIFO，追加少于 512 样本的真实末尾余量，不补零，再识别和翻译末句；立即停止则废弃旧代次的未完成工作。采样缺口先结束之前的有效语音并重置检测状态。
- VAD 模型缺失或加载/计算失败时记录诊断并回退原 RMS +600ms 静音断句；Windows 尚未随包提供 VAD 权重，使用回退路径。在线 livetranslate 的云端断句不受这个本地 VAD 控制。

## +9 提前断句修正

+8 的 384ms 静音门槛会把句中停顿当成结束；原迟滞逻辑在一次低于 0.35 后退回 0.5 起句门槛，随后的较轻语音可能被继续判为静音。过短片段减少 Whisper 上下文，96ms 尾音裁剪也可能漏掉弱词尾；这些都会影响后续文本翻译。

+9 修正上述边界和裁剪，预览仍按最小 500ms 自适应调度。普通确认的静音等待增加 1216ms；暂停/停止/EOF 直接排空，不等待这 1600ms。受控回归覆盖 192/384/800/1152/1408ms 句中停顿、概率跌落后的较轻续音、停止时漏判的尾音，以及预览在停止前保持可修订。

VAD 只估计声音活动，不保证语义句子完整。超过 1600ms 的真实停顿和 8s 窗上限仍会分段；单元测试不代表真实语音准确率。准确率需用同一个模型和同一段音频，与不含 VAD 的路线对照；不能把更早显示某个片段当成识别质量改善。

### +9 静音复验

同一 M2 / small / Metal，在完整公开 11s JFK 样本上进行一轮实际节奏离线对照，真实 EOF 不补零，不调用翻译服务。960ms 初步修正仍把 “Ask not.” 单独确认，因此最终改为 1600ms。当前 VAD 和同构建 RMS 路线均输出 2 段，“Ask not what your country can do for you”保留在同一段；按 22 个英文词比较，均无替换、遗漏和插入。旧 +8 在该样本中输出 4 段，词级 WER 虽为 0，却掩盖了不合适的语义边界。

当前 VAD 首次原文预览 1488ms，RMS 1372ms；最后原文确认相对 EOF 为 391ms / 367ms。一轮数值不作速度结论，未测当前 MT 译文时延，也不代表中文、噪声或影视对白准确率。公开数值见 [修正版摘要](benchmarks/vad-guard-2026-10-07.json)。

## +8 历史静音对照结果（M2 / small / Metal）

以下记录对应旧 +8 的 384ms / 96ms 策略，不代表 +9 修正后的结果。

一轮四种文件各跑两路，均无采样丢弃。以下为音频开始后的首段确认原文，以及最后确认原文相对 EOF 的时间；负数表示在 EOF 前已完成。两路首段的内容长度不同：VAD 先确认较短的“And so, my fellow Americans.”，RMS 等待 8s 大窗，不能解释成同一句完整长句提速。

| 输入 | 首段确认 RMS→VAD (ms) | 末段确认相对 EOF RMS→VAD (ms) | 最终原文 WER RMS→VAD |
| --- | ---: | ---: | ---: |
| 完整样本 +1200ms 静音 +完整重播 | 8426.9→2939.4 | +440.9→+507.7 | 0→0 |
| 完整样本 +200ms 静音 +完整重播 | 8396.2→2933.6 | +493.8→+537.2 | 20.45%→0 |
| 原样 11s +1200ms 尾静音 | 8412.0→2945.8 | −249.1→−590.9 | 0→0 |
| 原样 11s，真实 EOF 不补零 | 8520.9→2933.4 | +399.5→+544.6 | 0→0 |

真实 EOF 复测首段 8417.8→2933.3ms，末段 +363.3→+508.4ms，WER 均 0。结论是更早开始分段确认，真实 EOF 收尾仍慢约 145ms；不能说停止后的延迟已经降低。RMS 200ms 合成重播多出 9 个重复词，并非漏掉 9 词；其它样本及 VAD 完整词序均正确。干净单一英语样本不代表总体准确率。

VAD 在原样 JFK 自然停顿处分成 4 段，重播样本各 8 段，RMS 对应 2/4 段。VAD 将“Ask not.”和“What your country can do for you.”分开；词级 WER 不反映这种语义切分。文本翻译请求可能增加，独立翻译片段的语义也可能变弱，因此此分支保留为实验版本。源样本本身含停顿，200ms 插入静音与 >8s 文件都不能证明纯 200ms 短停顿或连续无停顿 8s 的边界质量，这些由受控单元测试覆盖。

真实 ASR 同时工作时，686 批 VAD worker 往返 P50 为 12.074ms，每音频秒累计约 120.5ms；独立 CPU 概率测试为平均 3.87ms、P95 4.48ms/100ms 输入。两者都包含对应调用开销，不能当进程 CPU 占用或功耗。13 次预览取消后的返回等待为 1.276–216.319ms，显示取消仍有原生计算等待；384ms 也只是检测规则，实测检测窗末到 final 入队还含 100ms 帧调度和 VAD 工作。

首轮八份数值完成后，测试 harness 因重复关闭同一 Whisper worker 在清理阶段挂起，已保留异常说明；修复关闭顺序后仅对真实 EOF 两路复验，正常 exit 0、worker 已关闭、测试通过。数值与退出审计见 [配对摘要](benchmarks/vad-endpoint-2026-10-07.json)。此问题只在测试 harness，未修改 Whisper 推理接口或安装副本。

## 验证与重现

普通单元测试使用受控概率和延迟 worker，验证迟滞、静音/短 burst、短停顿、前滚、精确 8s 边界、EOF 真余量、暂停、立即停止与取消晚回包；它们不代表 Silero 识别准确率。真实 CPU 验收在公开 JFK 样本上检查检测窗口/代次/重复块和关闭行为。

```sh
LUMA_WHISPER_LIBRARY="$PWD/build/whisper/liblumawhisper.dylib" \
LUMA_TEST_VAD_MODEL="$PWD/.tools/vad/ggml-silero-v5.1.2.bin" \
LUMA_TEST_WAV="$PWD/.tools/whisper.cpp/samples/jfk.wav" \
.tools/flutter/bin/flutter test test/vad_integration_test.dart --reporter expanded
```

配对端点基准使用同一完整公开 JFK PCM，另生成插入 1200ms、200ms 数字静音的完整样本重播，以及原样 11s EOF。生成的 WAV 在 ignored `build/` 中，基准桥只接受文件和 UI 更新，无法播放、采集或读取密钥。两路保持同一个 ASR 模型规格、语言、500ms 预览和实时节奏；对照路为 RMS 600ms +不抢占在途预览，当前实验路为 Silero 1600ms +final 抢占。历史 +8 为 384ms。不是与历史 +7 在线 MT 时间直接配对。

```sh
LUMA_WHISPER_LIBRARY="$PWD/build/whisper/liblumawhisper.dylib" \
LUMA_TEST_VAD_MODEL="$PWD/.tools/vad/ggml-silero-v5.1.2.bin" \
LUMA_TEST_WHISPER_MODEL=/绝对路径/ggml-small.bin \
LUMA_TEST_WHISPER_WAV="$PWD/.tools/whisper.cpp/samples/jfk.wav" \
LUMA_ENDPOINT_BENCHMARK_OUTPUT="$PWD/build/vad-endpoint-small.json" \
.tools/flutter/bin/flutter test test/vad_endpoint_benchmark_test.dart --reporter expanded
```

取消回应时间表示旧原生调用结束并被废弃，并不保证每次调用都在相同位置提前退出。报告区分 VAD 计算、已判语音末窗到入队、final 队列等待、预览取消回应、ASR、原文可见与 EOF 收尾。已判语音末窗不是人工标注的真实词尾。WER 只比较完整公开样本的 22/44 词最终原文；重复样本不是独立语料，无法推广到噪声、音乐、短命令或其它语言。此次不调用 MT API，不能把原文延迟称为最终译文延迟。

打包命令：

```sh
LUMA_OUTPUT_DIRECTORY="$PWD/dist/vad-guard" scripts/build_macos.sh
```

缺少正式签名和公证时仍为 ad-hoc 开发包；本次不替换稳定安装副本、不重做系统采集授权。

## +8 历史构建产物

实验 DMG 版本0.1.0+8，源码 `4b96b32`、构建时源码干净；12,139,080字节，SHA256 `f78ba4acf2482d3fa47fcff0f5ba8c2ca65165135cd719613bea4ae9afc72c62`。只读挂载签名验证和包内CPU VAD静音加载/公开fixture检查通过。此次包内首次加载1.509s（含动态库与worker初始化），稳态平均3.76ms/100ms；首次会话准备时间另计。仍为未公证的ad-hoc实验包，不替换已安装+7。

## +9 修正构建产物

实验 DMG 版本 0.1.0+9，应用源码 `6f2a202`、构建时源码干净，输出至 `dist/vad-guard/`。148 项普通测试和 6 项包内原生 Whisper / VAD 静音验收通过；分析无问题，只读挂载签名校验通过。未播放声音、未采集音频、未调用 MT 服务，未替换已安装副本或公开 +7 Release。

12139224 字节，SHA256 `2a18f7e21cbc23a2dd1b1a8b357d93a1d84f6e2f2fd96a0fa73dcb26cc0d57ce`；构建清单和校验文件与 DMG 同目录。仍为未公证的 ad-hoc 开发测试包。
