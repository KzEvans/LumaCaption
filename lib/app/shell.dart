import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/models/model_manager.dart';
import '../core/subtitles/subtitles.dart';
import 'controller.dart';
import 'design.dart';

class LumaApp extends StatefulWidget {
  const LumaApp({super.key, required this.controller});
  final AppController controller;
  @override
  State<LumaApp> createState() => _LumaAppState();
}

class _LumaAppState extends State<LumaApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.initialize();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => MaterialApp(
      title: 'LumaCaption',
      debugShowCheckedModeBanner: false,
      themeMode: switch (widget.controller.settings.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      theme: lumaTheme(Brightness.light),
      darkTheme: lumaTheme(Brightness.dark),
      home: Shell(c: widget.controller),
    ),
  );
}

class Shell extends StatefulWidget {
  const Shell({super.key, required this.c});
  final AppController c;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int page = 0;
  int? historySession;
  AppController get c => widget.c;
  Color get accent => Theme.of(context).colorScheme.primary;
  final labels = ['实时字幕', '模型管理', '翻译服务', '字幕外观', '历史与导出', '设置与诊断'];
  final icons = [
    Icons.subtitles_outlined,
    Icons.memory_outlined,
    Icons.translate_outlined,
    Icons.text_fields_outlined,
    Icons.history_outlined,
    Icons.tune_outlined,
  ];
  void run(Future<void> Function() fn) => c.guard(fn);
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      SingleActivator(
        LogicalKeyboardKey.enter,
        control: !Platform.isMacOS,
        meta: Platform.isMacOS,
      ): () =>
          run(c.running ? () => c.stop() : c.start),
      const SingleActivator(LogicalKeyboardKey.keyL, control: true): () =>
          run(c.toggleOverlay),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: Row(
          children: [
            _navigation(),
            Expanded(
              child: Column(
                children: [
                  _toolbar(),
                  Expanded(
                    child: !c.initialized
                        ? const Center(child: CircularProgressIndicator())
                        : _page(),
                  ),
                  if (c.error.isNotEmpty) _error(),
                  _statusbar(),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _navigation() => LayoutBuilder(
    builder: (context, constraints) {
      final extended = MediaQuery.sizeOf(context).width >= 1040;
      final colors = Theme.of(context).colorScheme;
      return NavigationRail(
        extended: extended,
        minWidth: 88,
        minExtendedWidth: 216,
        useIndicator: true,
        trailingAtBottom: true,
        scrollable: true,
        labelType: extended
            ? NavigationRailLabelType.none
            : NavigationRailLabelType.all,
        selectedIndex: page < 4 ? page : null,
        onDestinationSelected: (value) => setState(() => page = value),
        leading: Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.closed_caption_rounded,
                color: colors.primary,
                size: 32,
              ),
              if (extended) ...[
                const SizedBox(width: 12),
                Text(
                  'LumaCaption',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ],
          ),
        ),
        destinations: [
          for (var i = 0; i < 4; i++)
            NavigationRailDestination(
              icon: Icon(icons[i]),
              label: Text(labels[i]),
            ),
        ],
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 4; i < labels.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Tooltip(
                  message: labels[i],
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: page == i
                          ? colors.onSecondaryContainer
                          : colors.onSurfaceVariant,
                      backgroundColor: page == i
                          ? colors.secondaryContainer
                          : Colors.transparent,
                    ),
                    onPressed: () => setState(() => page = i),
                    child: extended
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icons[i]),
                              const SizedBox(width: 12),
                              Text(labels[i]),
                            ],
                          )
                        : Column(
                            children: [
                              Icon(icons[i]),
                              const SizedBox(height: 4),
                              Text(
                                labels[i],
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      );
    },
  );
  Widget _toolbar() => Container(
    height: 78,
    padding: const EdgeInsets.symmetric(horizontal: 28),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: Row(
      children: [
        Flexible(
          child: Text(
            labels[page],
            style: Theme.of(context).textTheme.headlineSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (c.testMode || c.fileInput) ...[
          const SizedBox(width: 12),
          Text(
            c.fileInput ? 'WAV 文件测试' : '离线采集测试',
            style: const TextStyle(fontSize: 12),
          ),
        ],
        const Spacer(),
        FilledButton.tonalIcon(
          onPressed: () => run(c.toggleOverlay),
          icon: Icon(
            c.overlayVisible ? Icons.picture_in_picture_alt : Icons.open_in_new,
            size: 17,
          ),
          label: Text(c.overlayVisible ? '隐藏悬浮窗' : '打开悬浮窗'),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: c.busy
              ? null
              : () => run(c.running ? () => c.stop() : c.start),
          icon: Icon(
            c.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
            size: 18,
          ),
          label: Text(c.running ? '停止字幕' : '开始字幕'),
        ),
      ],
    ),
  );
  Widget _page() => switch (page) {
    0 => _live(),
    1 => _models(),
    2 => _providers(),
    3 => _appearance(),
    4 => _history(),
    _ => _settings(),
  };
  Widget _statusbar() => Container(
    height: 36,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: Row(
      children: [
        Icon(
          c.running ? Icons.circle : Icons.circle_outlined,
          size: 8,
          color: c.running ? accent : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            c.status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ),
        Text(c.privacy, style: const TextStyle(fontSize: 11)),
      ],
    ),
  );
  Widget _error() => Container(
    color: Theme.of(context).colorScheme.errorContainer,
    padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
    child: Row(
      children: [
        Icon(
          Icons.error_outline,
          size: 18,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            c.error,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
        IconButton(
          tooltip: '关闭提示',
          onPressed: () {
            c.clearError();
          },
          icon: const Icon(Icons.close, size: 17),
        ),
      ],
    ),
  );
  Widget _scroll(List<Widget> children) =>
      ListView(padding: const EdgeInsets.all(28), children: children);
  Widget _card(Widget child) => Card(
    margin: const EdgeInsets.only(bottom: 18),
    child: Padding(padding: const EdgeInsets.all(22), child: child),
  );
  Widget _caption(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  );
  Widget _dropdown(
    String label,
    String value,
    Map<String, String> choices,
    void Function(String) onChanged, {
    bool enabled = true,
  }) => DropdownButtonFormField<String>(
    initialValue: choices.containsKey(value) ? value : choices.keys.first,
    decoration: InputDecoration(labelText: label),
    items: choices.entries
        .map(
          (e) => DropdownMenuItem(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: enabled && !c.running && !c.busy
        ? (v) {
            if (v != null) {
              onChanged(v);
              run(c.save);
            }
          }
        : null,
  );
  Widget _live() {
    final recent = c.subtitles.segments
        .where((s) => s.generation == c.generation)
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
          child: _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _dropdown('工作模式', c.settings.mode, {
                        'realtime': '千问实时音频翻译',
                        'text': '本地识别 + 文本翻译',
                        'offline': '离线原文字幕',
                      }, (v) => c.settings.mode = v),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: _dropdown(
                        '音频来源',
                        c.settings.source,
                        {'system': '系统声音', 'microphone': '麦克风'},
                        (v) {
                          c.settings.source = v;
                          c.settings.deviceId = '';
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _dropdown(
                        '输入设备',
                        c.settings.deviceId.isEmpty ? '' : c.settings.deviceId,
                        {
                          '': '系统默认',
                          for (final d in c.devices.where(
                            (d) => d['source'] == c.settings.source,
                          ))
                            d['id'] as String: d['name'] as String,
                        },
                        (v) => c.settings.deviceId = v,
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 160,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('输入电平', style: TextStyle(fontSize: 11)),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: (c.level * 5).clamp(0, 1),
                            minHeight: 5,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            c.running
                                ? '${(c.level * 100).toStringAsFixed(0)}%'
                                : '等待开始',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    OutlinedButton.icon(
                      onPressed: c.running && !c.busy
                          ? () => run(c.pause)
                          : null,
                      icon: Icon(
                        c.paused ? Icons.play_arrow : Icons.pause,
                        size: 16,
                      ),
                      label: Text(c.paused ? '继续' : '暂停'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 14,
                  runSpacing: 8,
                  children: [
                    _chip(Icons.shield_outlined, c.privacy),
                    _chip(Icons.memory, c.selectedModel),
                    if (c.settings.mode == 'realtime')
                      _chip(Icons.cloud_outlined, c.settings.modelId),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: recent.isEmpty
              ? _emptyLive()
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 20),
                  itemCount: recent.length,
                  reverse: true,
                  itemBuilder: (context, i) =>
                      _subtitle(recent[recent.length - 1 - i]),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
          child: Row(
            children: [
              Text(
                c.settings.mode == 'realtime'
                    ? '原文与译文分别显示；按真实关联信息对齐。'
                    : c.settings.mode == 'text'
                    ? '仅已确认原文进入文本翻译。'
                    : '本地原文字幕保留在当前会话内。',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: c.running
                    ? () => run(() => c.stop(emergency: true))
                    : null,
                icon: const Icon(Icons.stop_circle_outlined, size: 15),
                label: const Text('立即停止上传'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chip(IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        icon,
        size: 13,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 5),
      Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
  Widget _emptyLive() => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.graphic_eq_rounded, size: 30, color: accent),
            ),
            const SizedBox(height: 20),
            Text(
              c.running ? '正在聆听声音' : '字幕，从这里开始',
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              c.running ? '请播放视频或说话，字幕会在识别后出现。' : '选择声音来源与工作模式，然后开始。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 22),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: () => setState(() => page = 1),
                  icon: const Icon(Icons.download_outlined, size: 17),
                  label: const Text('选择本地模型'),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() => page = 2),
                  icon: const Icon(Icons.key_outlined, size: 17),
                  label: const Text('配置翻译服务'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '首次启动不会自动下载模型。',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _subtitle(SubtitleSegment s) => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              s.original.isNotEmpty ? '原文' : '译文',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: s.original.isNotEmpty
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : accent,
              ),
            ),
            const SizedBox(width: 9),
            Text(
              s.isFinal ? '已确认' : s.error ?? '识别中',
              style: const TextStyle(fontSize: 10),
            ),
            const Spacer(),
            if (s.startUs != null)
              Text(
                '${(s.startUs! / 1000000).toStringAsFixed(1)} s',
                style: const TextStyle(fontSize: 10),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (s.original.isNotEmpty)
          Semantics(
            label: s.original,
            excludeSemantics: true,
            child: SelectableText(
              s.original,
              style: const TextStyle(fontSize: 17, height: 1.65),
            ),
          ),
        if (s.translation.isNotEmpty || s.stash.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: s.original.isEmpty ? 0 : 8),
            child: Semantics(
              label: s.translation + s.stash,
              excludeSemantics: true,
              child: SelectableText(
                s.translation + s.stash,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w500,
                  height: 1.65,
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          s.engine,
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
  Widget _models() {
    final m = c.models;
    if (m == null) return const Center(child: Text('模型目录不可用'));
    return _scroll([
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _caption('在你的设备上识别声音'),
                Text(
                  '使用多语言 Whisper 模型，支持中文、日语、韩语等。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: c.running || c.loadingModel
                ? null
                : () => run(c.importModel),
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('导入模型'),
          ),
        ],
      ),
      const SizedBox(height: 22),
      _card(
        Row(
          children: [
            Icon(Icons.check_circle_outline, color: accent, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '当前模型：${c.selectedModel}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    c.whisper.ready
                        ? '已加载 · ${c.whisper.backend}'
                        : '选择「使用」后校验并加载',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            if (c.loadingModel)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
      for (final model in m.catalog) _modelRow(m, model),
      if (m.error != null)
        Text(
          m.error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _caption('模型存储'),
            SelectableText(m.directory, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              children: [
                OutlinedButton(
                  onPressed: c.running
                      ? null
                      : () => run(c.changeModelDirectory),
                  child: const Text('修改目录'),
                ),
                TextButton(
                  onPressed: () => run(
                    () =>
                        c.native.call<void>('openPath', {'path': m.directory}),
                  ),
                  child: const Text('打开文件夹'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '导入文件只检查兼容格式；无可信来源哈希时显示为未验证来源。实际加载会检查模型结构。',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _modelRow(ModelManager m, ModelEntry model) {
    final installed = m.installed.contains(model.id),
        active =
            m.activeId == model.id &&
            (m.downloading || m.paused || m.verifying);
    return _card(
      Column(
        children: [
          Row(
            children: [
              Container(
                width: 43,
                height: 43,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(Icons.memory_outlined, color: accent),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '多语言 · ${(model.bytes / 1048576).toStringAsFixed(0)} MB · 估计内存 ${model.memoryMB} MB · MIT',
                      style: const TextStyle(fontSize: 11),
                    ),
                    Text(
                      'whisper.cpp GGML · ${model.id == 'tiny'
                          ? '可用于首次验证'
                          : model.id == 'base'
                          ? '建议起点'
                          : '按硬件能力选择'}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (installed) ...[
                OutlinedButton(
                  onPressed: c.running || c.loadingModel
                      ? null
                      : () => run(() => c.loadModel(m.path(model))),
                  child: const Text('使用'),
                ),
                IconButton(
                  tooltip: '删除模型',
                  onPressed: c.running
                      ? null
                      : () => run(() => m.remove(model)),
                  icon: const Icon(Icons.delete_outline, size: 19),
                ),
              ] else if (active) ...[
                if (!m.verifying)
                  IconButton(
                    tooltip: m.paused ? '继续下载' : '暂停下载',
                    onPressed: () => run(() async {
                      if (m.paused) {
                        await m.download(model);
                      } else {
                        m.pause();
                      }
                    }),
                    icon: Icon(
                      m.paused ? Icons.play_arrow : Icons.pause,
                      size: 20,
                    ),
                  ),
                IconButton(
                  tooltip: '取消下载',
                  onPressed: m.verifying ? null : () => run(m.cancel),
                  icon: const Icon(Icons.close, size: 19),
                ),
              ] else
                FilledButton.tonalIcon(
                  onPressed: m.downloading || m.verifying
                      ? null
                      : () => run(() => m.download(model)),
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: const Text('下载'),
                ),
            ],
          ),
          if (active) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: m.verifying ? null : m.received / model.bytes,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                m.verifying
                    ? '校验 SHA256 与模型格式'
                    : '${m.paused ? '已暂停 · ' : ''}${(m.received / 1048576).toStringAsFixed(1)} / ${(model.bytes / 1048576).toStringAsFixed(0)} MB · ${(m.bytesPerSecond / 1048576).toStringAsFixed(1)} MB/s',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _providers() => _scroll([
    _caption('选择符合当前工作模式的服务'),
    const Text(
      '实时翻译上传音频；文本翻译只上传已确认原文。密钥按服务主机独立保存。',
      style: TextStyle(fontSize: 13),
    ),
    const SizedBox(height: 20),
    ProviderForm(c: c, key: ValueKey('provider-${c.settings.mode}')),
    const SizedBox(height: 8),
    _card(
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('默认千问实时模型', style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 8),
          SelectableText('qwen3.5-livetranslate-flash-realtime'),
          SizedBox(height: 8),
          Text(
            '纯文本字幕输出，单声道 16 kHz PCM 音频输入。源语言默认自动检测。云端原文识别需单独启用。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
  ]);
  Widget _appearance() => _scroll([
    _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _caption('独立悬浮字幕窗'),
          const Text(
            '字幕更新不会抢占键盘焦点。可拖动、缩放，并在菜单栏或托盘恢复交互。',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 22),
          _dropdown(
            '显示内容',
            c.settings.display,
            {'bilingual': '原文 + 译文', 'original': '仅原文', 'translation': '仅译文'},
            (v) {
              c.settings.display = v;
              run(c.configureOverlay);
            },
            enabled: true,
          ),
          const SizedBox(height: 18),
          Text('字体大小：${c.settings.fontSize.round()}'),
          Slider(
            value: c.settings.fontSize,
            min: 14,
            max: 72,
            onChanged: (v) {
              c.settings.fontSize = v;
              run(c.configureOverlay);
            },
          ),
          Text('背景不透明度：${(c.settings.opacity * 100).round()}%'),
          Slider(
            value: c.settings.opacity,
            min: .1,
            max: 1,
            onChanged: (v) {
              c.settings.opacity = v;
              run(c.configureOverlay);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('鼠标穿透'),
            subtitle: Text(
              Platform.isMacOS
                  ? '按 ⌃⌥⌘L 或菜单栏「恢复悬浮窗交互」。'
                  : '按 Ctrl+Alt+I 或托盘「恢复交互」。',
            ),
            value: c.clickThrough,
            onChanged: (v) {
              c.clickThrough = v;
              run(c.configureOverlay);
            },
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => run(c.toggleOverlay),
            icon: const Icon(Icons.picture_in_picture_alt, size: 17),
            label: Text(c.overlayVisible ? '隐藏悬浮窗' : '显示悬浮窗'),
          ),
        ],
      ),
    ),
    _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _caption('应用外观'),
          _dropdown('主题', c.settings.theme, {
            'system': '跟随系统',
            'light': '浅色',
            'dark': '深色',
          }, (v) => c.settings.theme = v),
        ],
      ),
    ),
  ]);
  Widget _history() => _scroll([
    Row(
      children: [
        Expanded(
          child: Text(
            '${c.subtitles.segments.length} 条字幕 · 默认仅保留在内存',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        TextButton.icon(
          onPressed: () => run(c.clearHistory),
          icon: const Icon(Icons.delete_outline, size: 17),
          label: const Text('清空历史'),
        ),
      ],
    ),
    const SizedBox(height: 18),
    _dropdown(
      '浏览与导出会话',
      historySession != null &&
              c.subtitles.segments.any((s) => s.generation == historySession)
          ? '$historySession'
          : 'all',
      {
        'all': '全部会话（跨会话导出使用 TXT）',
        for (final g
            in (c.subtitles.segments.map((s) => s.generation).toSet().toList()
              ..sort()))
          '$g': '会话 $g',
      },
      (v) => historySession = int.tryParse(v),
    ),
    _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _caption('导出已确认字幕'),
          const Text(
            'TXT 支持全部确认字幕。SRT/VTT 只导出有可靠音频时间的片段；云端原文与译文可能为独立流。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
          for (final display in ['bilingual', 'original', 'translation'])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 90,
                    child: Text(
                      display == 'bilingual'
                          ? '双语'
                          : display == 'original'
                          ? '原文'
                          : '译文',
                    ),
                  ),
                  for (final format in ['txt', 'srt', 'vtt'])
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: OutlinedButton(
                        onPressed: () => run(
                          () => c.export(
                            format,
                            display,
                            session: historySession,
                          ),
                        ),
                        child: Text(format.toUpperCase()),
                      ),
                    ),
                ],
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('将历史保存到本机'),
            subtitle: const Text('只保存已确认字幕，重启后可浏览。关闭保存后，已有历史仍保留，可随时清空。'),
            value: c.settings.persistHistory,
            onChanged: (v) {
              run(() => c.setPersistHistory(v));
            },
          ),
        ],
      ),
    ),
    for (final s
        in c.subtitles.segments.reversed
            .where(
              (s) => historySession == null || s.generation == historySession,
            )
            .take(30))
      _subtitle(s),
  ]);
  Widget _settings() => _scroll([
    _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _caption('音频与权限'),
          for (final e in c.permissions.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('${e.key}：${e.value}'),
            ),
          OutlinedButton.icon(
            onPressed: () => run(c.refreshDevices),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('刷新设备与权限'),
          ),
          const SizedBox(height: 14),
          const Text(
            '系统声音使用 ScreenCaptureKit / WASAPI loopback。受保护音频及部分独占输出可能无法采集。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
    _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _caption('测试音频文件'),
          const Text(
            '切换到离线模式后，使用你有权处理的 PCM16 / float32 WAV 文件验证真实识别。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: c.running || c.busy ? null : () => run(c.processFile),
            icon: const Icon(Icons.audio_file_outlined, size: 16),
            label: const Text('选择 WAV 并识别'),
          ),
        ],
      ),
    ),
    _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _caption('Windows 系统语音识别'),
          const Text(
            '当前基础版使用 Whisper。Windows AI Speech 尚未完成 SDK 编译与持续系统音频验证，暂不提供选择。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
    _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _caption('运行诊断'),
          Text(
            '本地 RTF：${c.rtf.toStringAsFixed(2)} · 推理耗时：${c.finalLatencyMs ?? 0} ms · 丢弃帧/任务：${c.droppedFrames}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(
            '收到 ${c.receivedFrames} 帧 · ${(c.receivedSamples / 16000).toStringAsFixed(1)} 秒音频 · 峰值 RMS ${c.peakLevel.toStringAsFixed(3)}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          const Text(
            '诊断仅记录状态，不包含字幕、音频和认证信息。关闭主窗口后可从菜单栏/托盘打开；退出会释放音频与网络任务。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          SelectableText(
            c.diagnostics.isEmpty ? '暂无记录' : c.diagnostics.join('\n'),
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
        ],
      ),
    ),
  ]);
}

class ProviderForm extends StatefulWidget {
  const ProviderForm({super.key, required this.c});
  final AppController c;
  @override
  State<ProviderForm> createState() => _ProviderFormState();
}

class _ProviderFormState extends State<ProviderForm> {
  final keyField = TextEditingController();
  late final TextEditingController workspace, endpoint, model, proxy;
  AppController get c => widget.c;
  bool get text => c.settings.mode == 'text';
  bool reveal = false;
  @override
  void initState() {
    super.initState();
    workspace = TextEditingController(text: c.settings.workspace);
    endpoint = TextEditingController(
      text: text ? c.settings.textBaseUrl : c.settings.endpoint,
    );
    model = TextEditingController(
      text: text ? c.settings.textModel : c.settings.modelId,
    );
    proxy = TextEditingController(text: c.settings.proxy);
  }

  @override
  void dispose() {
    for (final t in [keyField, workspace, endpoint, model, proxy]) {
      t.dispose();
    }
    super.dispose();
  }

  void apply() {
    c.settings.workspace = workspace.text.trim();
    c.settings.proxy = proxy.text.trim();
    if (text) {
      c.settings.textBaseUrl = endpoint.text.trim();
      c.settings.textModel = model.text.trim();
    } else {
      c.settings.endpoint = endpoint.text.trim();
      c.settings.modelId = model.text.trim();
    }
  }

  Widget field(String label, TextEditingController t, {String? hint}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: TextField(
          controller: t,
          enabled: !c.running,
          decoration: InputDecoration(labelText: label, hintText: hint),
          onChanged: (_) => apply(),
        ),
      );
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text ? '文本翻译服务' : '千问实时音频翻译',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 22),
          if (text)
            DropdownButtonFormField<String>(
              initialValue: c.settings.textProvider,
              decoration: const InputDecoration(labelText: '适配器'),
              items: const [
                DropdownMenuItem(value: 'qwen', child: Text('Qwen-MT')),
                DropdownMenuItem(
                  value: 'openai',
                  child: Text('OpenAI-compatible'),
                ),
              ],
              onChanged: c.running
                  ? null
                  : (v) {
                      setState(() {
                        c.settings.textProvider = v!;
                        model.text = v == 'qwen' ? 'qwen-mt-flash' : '';
                        apply();
                      });
                    },
            ),
          if (text) const SizedBox(height: 18),
          if (!text) ...[
            DropdownButtonFormField<String>(
              initialValue: c.settings.region,
              decoration: const InputDecoration(labelText: '地域（须与密钥匹配）'),
              items: const [
                DropdownMenuItem(value: 'cn-beijing', child: Text('北京')),
                DropdownMenuItem(value: 'ap-southeast-1', child: Text('新加坡')),
              ],
              onChanged: c.running
                  ? null
                  : (v) {
                      setState(() => c.settings.region = v!);
                    },
            ),
            const SizedBox(height: 18),
            field('Workspace ID', workspace),
          ],
          field(
            text ? 'Base URL' : 'WebSocket Endpoint（留空使用地域模板）',
            endpoint,
            hint: text
                ? 'https://服务主机/compatible-mode/v1'
                : 'wss://{WorkspaceId}.${c.settings.region}.maas.aliyuncs.com/api-ws/v1/realtime',
          ),
          field('模型 ID', model),
          TextField(
            controller: keyField,
            enabled: !c.running,
            obscureText: !reveal,
            decoration: InputDecoration(
              labelText: 'API Key',
              helperText: '留空保留此主机已有凭据。更换主机后需重新保存对应密钥。',
              suffixIcon: IconButton(
                tooltip: reveal ? '隐藏密钥' : '显示密钥',
                onPressed: () => setState(() => reveal = !reveal),
                icon: Icon(reveal ? Icons.visibility_off : Icons.visibility),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: c.settings.sourceLanguage,
                  decoration: const InputDecoration(labelText: '源语言'),
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('自动检测')),
                    DropdownMenuItem(value: 'zh', child: Text('中文')),
                    DropdownMenuItem(value: 'en', child: Text('英语')),
                    DropdownMenuItem(value: 'ja', child: Text('日语')),
                    DropdownMenuItem(value: 'ko', child: Text('韩语')),
                  ],
                  onChanged: c.running
                      ? null
                      : (v) => c.settings.sourceLanguage = v!,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: c.settings.targetLanguage,
                  decoration: const InputDecoration(labelText: '目标语言'),
                  items: const [
                    DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                    DropdownMenuItem(value: 'en', child: Text('英语')),
                    DropdownMenuItem(value: 'ja', child: Text('日语')),
                    DropdownMenuItem(value: 'ko', child: Text('韩语')),
                  ],
                  onChanged: c.running
                      ? null
                      : (v) => c.settings.targetLanguage = v!,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          field('HTTP 代理（可选）', proxy, hint: 'http://127.0.0.1:端口'),
          if (!text)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用云端原文识别'),
              subtitle: const Text('可在无本地模型时显示原文，可能产生额外服务费用。'),
              value: c.settings.cloudTranscription,
              onChanged: c.running
                  ? null
                  : (v) => setState(() => c.settings.cloudTranscription = v),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: c.running
                    ? null
                    : () => c.guard(() async {
                        apply();
                        if (keyField.text.isNotEmpty) {
                          await c.saveKey(keyField.text, text: text);
                          keyField.clear();
                        } else {
                          await c.save();
                        }
                      }),
                icon: const Icon(Icons.check, size: 17),
                label: const Text('保存配置'),
              ),
              OutlinedButton.icon(
                onPressed: c.running
                    ? null
                    : () => c.guard(() async {
                        apply();
                        await c.save();
                        await c.testConnection();
                      }),
                icon: const Icon(Icons.wifi_tethering, size: 17),
                label: const Text('测试连接（可能产生费用）'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
