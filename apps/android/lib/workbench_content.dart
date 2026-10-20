import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'connection.dart';
import 'session_widget.dart';
import 'dashboard_widgets.dart';
import 'layout_debug.dart';
export 'layout_debug.dart';
export 'workbench_data.dart' show workbenchTime;
import 'layout_workspace.dart';
import 'rawblock.dart';
import 'top_notice.dart';
import 'workbench_data.dart';

String _shortcutAlignment(Map<String, dynamic> options) {
  const values = {'left', 'center', 'spaceEvenly', 'right'};
  final value = options['alignment'];
  return value is String && values.contains(value) ? value : 'spaceEvenly';
}

String _shortcutAlignmentLabel(String alignment) => switch (alignment) {
  'left' => '左对齐',
  'center' => '居中对齐',
  'right' => '右对齐',
  _ => '均匀分布',
};

MainAxisAlignment _shortcutMainAxisAlignment(String alignment) =>
    switch (alignment) {
      'left' => MainAxisAlignment.start,
      'center' => MainAxisAlignment.center,
      'right' => MainAxisAlignment.end,
      _ => MainAxisAlignment.spaceEvenly,
    };

class WorkbenchWidgetBody extends StatelessWidget {
  const WorkbenchWidgetBody({
    super.key,
    required this.connection,
    required this.id,
    required this.type,
    required this.options,
    required this.binding,
    this.editing = false,
    this.onEditRequested,
    this.onTheme,
    this.onSettings,
    this.debugLayout = false,
    this.debugHovered = false,
    this.debugForceBorder = false,
    this.debugForceLabel = false,
  });
  final Connection connection;
  final String id, type;
  final Map<String, dynamic> options, binding;
  final bool editing, debugLayout;
  final bool debugHovered, debugForceBorder, debugForceLabel;
  final VoidCallback? onEditRequested, onTheme, onSettings;
  bool get online => connection.phase == ConnectionPhase.online;
  Future<void> open(
    BuildContext context,
    String action,
    String target,
    String version,
  ) async {
    if (editing) return;
    final message = await connection.open(action, target, version);
    if (context.mounted && message != null) {
      showTopNotice(context, message);
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPress: editing ? null : onEditRequested,
    child: LayoutBuilder(
      builder: (context, box) => LayoutDebugOverlay(
        enabled: debugLayout,
        forceBorder: debugForceBorder || debugHovered || debugForceLabel,
        forceLabel: debugForceLabel || debugHovered,
        label:
            '区域 ${box.maxWidth.toStringAsFixed(1)} × ${box.maxHeight.toStringAsFixed(1)} dp',
        top: true,
        child: _body(context),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    if (type == 'statusBar') {
      return WorkbenchStatusBar(
        connection: connection,
        options: options,
        onTheme: onTheme,
        onSettings: onSettings,
        editing: editing,
      );
    }

    if (!const {'sessions', 'usage', 'shortcuts'}.contains(type)) {
      return const _Message('此组件暂不受支持。原有配置已保留，可更新应用后查看。');
    }
    final data = connection.data;
    if (data == null) return const _Message('正在等待电脑共享内容。请在电脑的设备卡片中选择需要共享的内容。');
    if (binding['hostId'] != null &&
        binding['hostId'] != '' &&
        binding['hostId'] != data.hostId) {
      return const _Message('此组件绑定的电脑尚未连接。可以在组件设置中更换来源。');
    }
    final source = binding['source'] as String?;
    if (source != null &&
        source.isNotEmpty &&
        source != 'codex' &&
        !switch (type) {
          'sessions' => source == 'codex.sessions',
          'shortcuts' => source == 'host.shortcuts',
          'usage' =>
            source ==
                ((options['content'] == 'api')
                    ? 'sub2api.usage'
                    : 'codex.quota'),
          _ => true,
        }) {
      return const _Message('来源与当前内容不匹配，请在组件设置中选择来源。');
    }
    return switch (type) {
      'sessions' => _sessions(context, data),
      'shortcuts' =>
        options['appearance'] == 'dock'
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: deskbarColors(context).surface,
                  border: Border(
                    top: BorderSide(color: deskbarColors(context).line),
                  ),
                ),
                child: _shortcuts(context, data),
              )
            : _shortcuts(context, data),
      'usage' => _usage(context, data),
      _ => const _Message('此组件暂不受支持。原有配置已保留，可更新应用后查看。'),
    };
  }

  String _sourceStatusLabel(WorkbenchData data, String sourceId) {
    final s = data.source(sourceId);
    if (s == null) return '请在电脑的设备卡片中开启共享。';
    final stale = !online || !s.fresh(data.now);
    final label = stale
        ? (!online
              ? '电脑离线 · 上次数据'
              : s.message.isNotEmpty
              ? s.message
              : '数据已过期，等待刷新')
        : '上次更新';
    return '$label${s.observedAt > 0 ? ' · ${workbenchTime(s.observedAt)}' : ''}';
  }

  Widget _status(BuildContext context, WorkbenchData data, String sourceId) {
    final s = data.source(sourceId);
    final c = deskbarColors(context);
    return Text(
      _sourceStatusLabel(data, sourceId),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: s != null && (!online || !s.fresh(data.now))
            ? c.warning
            : c.muted,
      ),
    );
  }

  Widget _sessions(BuildContext context, WorkbenchData data) {
    final source = data.source('codex.sessions');
    if (source == null) return const _Message('请在电脑端开启「近期会话」共享。');
    final fresh = online && source.fresh(data.now);
    final allowed = data.capabilities.contains('open_session');
    return AdaptiveSessions(
      key: ValueKey('sessions-$id'),
      id: id,
      sessions: data.sessions,
      visibleCount: sessionDisplayLimit(options),
      columns: options['columns'] is int ? options['columns'] as int : null,
      now: data.now,
      notice: [
        if (!fresh) _sourceStatusLabel(data, 'codex.sessions'),
        if (!allowed && data.sessions.isNotEmpty) '请在电脑端开启「允许在电脑上打开」。',
      ].join(' · '),
      onOpen: !editing && fresh && allowed && !connection.opening
          ? (session) =>
                open(context, 'open_session', session.id, session.version)
          : null,
      debugLayout: debugLayout,
    );
  }

  Widget _shortcuts(BuildContext context, WorkbenchData data) {
    final resource = binding['resourceId'];
    final entries = data.shortcuts
        .where((s) => resource == null || resource == '' || s.id == resource)
        .toList();
    if (entries.isEmpty) {
      return _Message(
        resource != null && resource != ''
            ? '绑定的入口不在共享范围，请在电脑端调整来源。'
            : '请在电脑端添加入口并开启共享。',
      );
    }
    final labelsRequested = options['labels'] == true;
    final alignment = _shortcutAlignment(options);
    final allowed = data.capabilities.contains('open_shortcut');
    final canOpen = !editing && online && allowed && !connection.opening;
    final labelStyle = Theme.of(
      context,
    ).textTheme.labelLarge!.copyWith(fontWeight: FontWeight.w400);
    final notice = !online
        ? '电脑离线 · 暂时无法打开'
        : !allowed
        ? '请在电脑端开启「允许在电脑上打开」。'
        : '';
    return Padding(
      padding: const EdgeInsets.all(4),
      child: LayoutBuilder(
        builder: (context, box) {
          final requestedGap = alignment == 'center'
              ? shortcutSpacing(options)
              : 8.0;
          final noticePainter = TextPainter(
            text: TextSpan(
              text: notice,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: math.max(1, box.maxWidth));
          final noticeHeight = notice.isEmpty ? 0.0 : noticePainter.height + 4;
          noticePainter.dispose();
          final availableHeight = math.max(1.0, box.maxHeight - noticeHeight);
          final limit = shortcutDisplayLimit(options);
          final capacity = limit > 0
              ? math.min(limit, entries.length)
              : entries.length;
          final rows = math.min(shortcutRows(options), capacity);
          final columns = (capacity / rows).ceil();
          final gapX = limit > 0
              ? math.min(requestedGap, box.maxWidth / (columns * 2))
              : requestedGap;
          const gapY = 8.0;
          final rowHeight = math.max(
            1.0,
            (availableHeight - gapY * (rows - 1)) / rows,
          );
          final cellWidth = limit > 0
              ? math.max(1.0, (box.maxWidth - gapX * (columns - 1)) / columns)
              : double.infinity;
          final labels = labelsRequested && rowHeight >= 96 && cellWidth >= 48;
          final labelHeight = labels
              ? MediaQuery.textScalerOf(context).scale(labelStyle.fontSize!) *
                        (labelStyle.height ?? 1.5) *
                        2 +
                    4
              : 0.0;
          // Unlimited grids keep their icon size when narrowed. Limited pages
          // fit their configured capacity into the available rows and width.
          final iconSize = math.min(
            (rowHeight - labelHeight - 8).clamp(16.0, 200.0),
            cellWidth,
          );
          final tileWidth = math.min(math.max(48.0, iconSize), cellWidth);
          final contentHeight = iconSize + labelHeight + 8;
          final tileHeight = math.min(rowHeight, math.max(48.0, contentHeight));
          final gridHeight = tileHeight * rows + gapY * (rows - 1);
          final contentWidth = columns * tileWidth + (columns - 1) * gapX;
          final pageCount = (entries.length / capacity).ceil();
          final overflow = limit > 0
              ? pageCount > 1
              : contentWidth > box.maxWidth;
          if (rowHeight < contentHeight) {
            return _Message(
              '${notice.isEmpty ? '' : '$notice。'}入口区域太矮，请在电脑端调整高度或减少行数。',
            );
          }
          Widget tile(WorkShortcut entry) {
            final c = deskbarColors(context);
            Widget fallback() => Container(
              width: iconSize,
              height: iconSize,
              decoration: BoxDecoration(
                color: c.raised,
                borderRadius: BorderRadius.circular(iconSize * .2),
              ),
              child: Icon(
                entry.kind == 'app'
                    ? Icons.apps_outlined
                    : Icons.language_outlined,
                size: iconSize * .65,
                color: c.muted,
              ),
            );
            return LayoutDebugOverlay(
              key: ValueKey('shortcut-$id-${entry.id}'),
              enabled: debugLayout,
              label:
                  '单元 ${tileWidth.toStringAsFixed(1)} × ${tileHeight.toStringAsFixed(1)} dp · 图标 ${iconSize.toStringAsFixed(1)} dp',
              top: true,
              child: SizedBox(
                width: tileWidth,
                height: tileHeight,
                child: Tooltip(
                  message: entry.name,
                  child: Semantics(
                    label: entry.name,
                    button: !editing,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: canOpen
                          ? () => open(
                              context,
                              'open_shortcut',
                              entry.id,
                              entry.version,
                            )
                          : null,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (entry.iconBytes != null)
                            Image.memory(
                              entry.iconBytes!,
                              width: iconSize,
                              height: iconSize,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.medium,
                              errorBuilder: (context, error, stack) =>
                                  fallback(),
                            )
                          else
                            fallback(),
                          if (labels) ...[
                            const SizedBox(height: 4),
                            Text(
                              entry.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: labelStyle,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }

          Widget grid(List<WorkShortcut> items) => SizedBox(
            width: math.max(box.maxWidth, contentWidth),
            height: gridHeight,
            child: Column(
              children: [
                for (var row = 0; row < rows; row++) ...[
                  if (row > 0) const SizedBox(height: gapY),
                  SizedBox(
                    height: tileHeight,
                    child: Row(
                      mainAxisAlignment: _shortcutMainAxisAlignment(alignment),
                      children: [
                        for (var col = 0; col < columns; col++)
                          if (row * columns + col < items.length) ...[
                            if (col > 0) SizedBox(width: gapX),
                            tile(items[row * columns + col]),
                          ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
          final scrollPhysics = overflow
              ? const AlwaysScrollableScrollPhysics(
                  parent: ClampingScrollPhysics(),
                )
              : const NeverScrollableScrollPhysics();
          final content = limit > 0
              ? PageView.builder(
                  key: PageStorageKey('shortcuts-$id'),
                  physics: scrollPhysics,
                  itemCount: pageCount,
                  itemBuilder: (context, page) => grid(
                    entries.sublist(
                      page * capacity,
                      math.min((page + 1) * capacity, entries.length),
                    ),
                  ),
                )
              : SingleChildScrollView(
                  key: PageStorageKey('shortcuts-$id'),
                  primary: false,
                  scrollDirection: Axis.horizontal,
                  physics: scrollPhysics,
                  child: grid(entries),
                );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (notice.isNotEmpty) ...[
                Text(
                  notice,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: deskbarColors(context).warning,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Expanded(
                child: LayoutDebugOverlay(
                  enabled: debugLayout,
                  label:
                      '单元 ${tileWidth.toStringAsFixed(1)} × ${tileHeight.toStringAsFixed(1)} dp · 图标 ${iconSize.toStringAsFixed(1)} dp · 间距 $gapX dp · ${_shortcutAlignmentLabel(alignment)}',
                  child: Center(
                    child: SizedBox(
                      height: gridHeight,
                      child: Listener(
                        onPointerSignal: overflow
                            ? (event) {
                                if (event is PointerScrollEvent &&
                                    event.scrollDelta.dx.abs() >
                                        event.scrollDelta.dy.abs()) {
                                  // The child scrollable gets first refusal. Consume horizontal
                                  // wheel events at its ends too, instead of switching pages.
                                  GestureBinding.instance.pointerSignalResolver
                                      .register(event, (_) {});
                                }
                              }
                            : null,
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(
                            context,
                          ).copyWith(scrollbars: false),
                          child: content,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _usage(BuildContext context, WorkbenchData data) {
    final api = options['content'] == 'api';
    final sourceId = api ? 'sub2api.usage' : 'codex.quota';
    final resource = binding['resourceId'];
    final quotas = data.quotas
        .where((q) => resource == null || resource == '' || q.id == resource)
        .toList();
    final usages = data.apiUsage
        .where((u) => resource == null || resource == '' || u.id == resource)
        .toList();
    if (resource != null &&
        resource != '' &&
        (api ? usages.isEmpty : quotas.isEmpty)) {
      return const _Message('绑定的用量资源已不在共享范围，请在组件设置中重新选择。');
    }
    if (api && usages.isEmpty) {
      return _Message(
        data.source(sourceId) == null
            ? '请在电脑端开启「API 用量」共享。'
            : '暂时没有 API 用量，请在电脑端检查用量来源。',
      );
    }
    if (!api && quotas.isEmpty) {
      return _Message(
        data.source(sourceId) == null
            ? '请在电脑端开启「Codex 额度」共享。'
            : '暂时没有可用额度，请在电脑上确认 Codex 已登录。',
      );
    }
    final detailMessage = api
        ? usages
              .map(
                (u) => [
                  u.label,
                  _apiCost(u),
                  'Token ${_quantity(u.tokenCount)} · TPM ${_quantity(u.tpm)}',
                  '统计窗口 ${workbenchTime(u.windowStart)} — ${workbenchTime(u.windowEnd)}',
                  if (u.windowEnd <= data.now) '上次数据，等待刷新',
                ].join('\n'),
              )
              .join('\n\n')
        : quotas
              .map(
                (q) => [
                  q.label,
                  q.resetsAt <= data.now
                      ? '等待刷新'
                      : '${q.remaining.round()}% 剩余',
                  '${workbenchTime(q.resetsAt)} 重置',
                ].join('\n'),
              )
              .join('\n\n');

    if (!api) {
      final q = quotas.first;
      final fresh = online && (data.source(sourceId)?.fresh(data.now) ?? false);
      return Tooltip(
        message: detailMessage,
        child: LayoutDebugOverlay(
          enabled: debugLayout,
          label: '额度 · 自适应排版',
          top: true,
          child: QuotaSidebar(
            quota: q,
            now: data.now,
            debugLayout: debugLayout,
            fresh: fresh,
            numberKey: ValueKey('usage-number-$id'),
            status: _status(context, data, sourceId),
          ),
        ),
      );
    }
    final usage = usages.first;
    final fresh =
        online &&
        (data.source(sourceId)?.fresh(data.now) ?? false) &&
        usage.windowEnd > data.now;
    return Tooltip(
      message: detailMessage,
      child: AdaptiveMetrics(
        debugLayout: debugLayout,
        primary: MetricValue(
          label: fresh ? '实际成本' : '上次实际成本',
          value: _apiCost(usage),
          valueKey: ValueKey('usage-number-$id'),
        ),
        secondary: [
          MetricValue(label: 'Token', value: _quantity(usage.tokenCount)),
          MetricValue(label: 'TPM', value: _quantity(usage.tpm)),
        ],
        status: fresh
            ? null
            : Text(
                usage.windowEnd <= data.now
                    ? '统计窗口已结束 · 等待刷新'
                    : _sourceStatusLabel(data, sourceId),
                style: TextStyle(color: deskbarColors(context).warning),
              ),
      ),
    );
  }
}

String _apiCost(WorkApiUsage usage) {
  final prefix = usage.currency == 'USD' ? r'$' : '${usage.currency} ';
  return '$prefix${(usage.actualCostMicros / 1000000).toStringAsFixed(2)}';
}

String _quantity(int value) => value >= 1000000
    ? '${(value / 1000000).toStringAsFixed(1)}M'
    : value >= 1000
    ? '${(value / 1000).toStringAsFixed(1)}K'
    : '$value';

class _Message extends StatelessWidget {
  const _Message(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      padding: const EdgeInsets.all(4),
      child: Text(message, style: Theme.of(context).textTheme.bodySmall),
    ),
  );
}

// A vertically flowing preview retained for integration fixtures and diagnostics.
class WorkbenchContent extends StatelessWidget {
  const WorkbenchContent({super.key, required this.connection});
  final Connection connection;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final entry in [
        ('Codex 额度', 'usage', 280.0),
        ('快捷入口', 'shortcuts', 260.0),
        ('近期会话', 'sessions', 340.0),
      ]) ...[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(entry.$1, style: Theme.of(context).textTheme.titleLarge),
        ),
        SizedBox(
          height: entry.$2 == 'sessions'
              ? MediaQuery.textScalerOf(context).scale(entry.$3)
              : entry.$3,
          child: Card(
            child: WorkbenchWidgetBody(
              connection: connection,
              id: entry.$2,
              type: entry.$2,
              options: const {},
              binding: const {},
            ),
          ),
        ),
      ],
    ],
  );
}
