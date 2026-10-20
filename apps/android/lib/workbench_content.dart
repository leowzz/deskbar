import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'connection.dart';
import 'dashboard_widgets.dart';
import 'layout_workspace.dart';
import 'rawblock.dart';
import 'top_notice.dart';
import 'workbench_data.dart';

const sessionCompactMinimumHeight = 88.0;
const sessionStandardMinimumHeight = 96.0;

double sessionMinimumHeight({required bool compact}) =>
    compact ? sessionCompactMinimumHeight : sessionStandardMinimumHeight;

String workbenchTime(int seconds) {
  if (seconds <= 0) return '未知';
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}';
}

class _ShortcutLayout {
  const _ShortcutLayout({
    required this.iconSize,
    required this.tileWidth,
    required this.tileHeight,
    required this.columns,
    required this.rows,
  });

  final double iconSize;
  final double tileWidth;
  final double tileHeight;
  final int columns;
  final int rows;
}

int? _shortcutRows(Map<String, dynamic> options) {
  final value = options['rows'];
  if (value is num && value.isFinite && value == value.round()) {
    return value.round().clamp(1, 12).toInt();
  }
  return null;
}

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

String _usageDensity(Map<String, dynamic> options) {
  const values = {'compact', 'standard', 'fill'};
  final value = options['density'];
  return value is String && values.contains(value) ? value : 'fill';
}

String _usageDensityLabel(String density) => switch (density) {
  'compact' => '紧凑',
  'standard' => '标准',
  _ => '自适应填充',
};

String _usageAlignment(Map<String, dynamic> options) {
  const values = {'top', 'center', 'spaceEvenly', 'bottom'};
  final value = options['alignment'];
  return value is String && values.contains(value) ? value : 'spaceEvenly';
}

String _usageAlignmentLabel(String alignment) => switch (alignment) {
  'top' => '顶部对齐',
  'center' => '居中对齐',
  'bottom' => '底部对齐',
  _ => '均匀分布',
};

MainAxisAlignment _usageMainAxisAlignment(String alignment) =>
    switch (alignment) {
      'top' => MainAxisAlignment.start,
      'center' => MainAxisAlignment.center,
      'bottom' => MainAxisAlignment.end,
      _ => MainAxisAlignment.spaceEvenly,
    };

MainAxisAlignment _shortcutMainAxisAlignment(String alignment) =>
    switch (alignment) {
      'left' => MainAxisAlignment.start,
      'center' => MainAxisAlignment.center,
      'right' => MainAxisAlignment.end,
      _ => MainAxisAlignment.spaceEvenly,
    };

_ShortcutLayout _calculateShortcutLayout({
  required int count,
  required double width,
  required double height,
  required double gapX,
  required double gapY,
  required bool labels,
  required double labelHeight,
  required bool maximize,
  required int? configuredRows,
  double fixedIconSize = 56,
}) {
  final horizontalPadding = labels ? 32.0 : 8.0;
  final verticalPadding = labels ? labelHeight + 8.0 : 8.0;
  if (!maximize) {
    final iconSize = fixedIconSize.clamp(24, 200).toDouble();
    final tileWidth = math.max(48.0, iconSize + horizontalPadding).toDouble();
    final tileHeight = math.max(48.0, iconSize + verticalPadding).toDouble();
    final maxColumns = math
        .max(1, ((width + gapX) / (tileWidth + gapX)).floor())
        .toInt();
    final requestedRows = configuredRows ?? (count / maxColumns).ceil();
    final columns = math.max(
      1,
      math.min(maxColumns, (count / requestedRows).ceil()).toInt(),
    );
    final rows = (count / columns).ceil();
    return _ShortcutLayout(
      iconSize: iconSize,
      tileWidth: tileWidth,
      tileHeight: tileHeight,
      columns: columns,
      rows: rows,
    );
  }

  final firstCandidate = math.min(configuredRows ?? 1, count);
  final candidates = Iterable<int>.generate(
    count - firstCandidate + 1,
    (index) => firstCandidate + index,
  );
  var bestRows = configuredRows ?? 1;
  var bestColumns = count;
  var bestIcon = 24.0;
  var bestRawIcon = -double.infinity;
  for (final candidateRows in candidates) {
    final columns = math.max(1, (count / candidateRows).ceil()).toInt();
    final iconByWidth =
        (width - gapX * (columns - 1)) / columns - horizontalPadding;
    final iconByHeight =
        (height - gapY * (candidateRows - 1)) / candidateRows - verticalPadding;
    final rawIcon = math.min(iconByWidth, iconByHeight);
    if (rawIcon > bestRawIcon ||
        (rawIcon == bestRawIcon && candidateRows < bestRows)) {
      bestRows = candidateRows;
      bestColumns = columns;
      bestRawIcon = rawIcon;
      bestIcon = rawIcon.clamp(24, 200).toDouble();
    }
  }
  final iconSize = bestIcon;
  return _ShortcutLayout(
    iconSize: iconSize,
    tileWidth: math.max(48.0, iconSize + horizontalPadding).toDouble(),
    tileHeight: math.max(48.0, iconSize + verticalPadding).toDouble(),
    columns: bestColumns,
    rows: bestRows,
  );
}

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
  double number(String key, double fallback) {
    final value = options[key];
    return value is num ? value.toDouble() : fallback;
  }

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
    final sessions = data.sessions.take(sessionDisplayLimit(options)).toList();
    final fresh = online && source.fresh(data.now);
    final allowed = data.capabilities.contains('open_session');
    final canOpen = !editing && fresh && allowed && !connection.opening;
    return LayoutBuilder(
      builder: (context, box) {
        final compact = options['density'] == 'compact';
        final style = Theme.of(context).textTheme.bodySmall!;
        final notice = [
          if (!fresh) _sourceStatusLabel(data, 'codex.sessions'),
          if (!allowed && sessions.isNotEmpty) '请在电脑端开启「允许在电脑上打开」。',
        ].join(' · ');
        const padding = 4.0;
        final painter = TextPainter(
          text: TextSpan(text: notice, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: math.max(1, box.maxWidth - padding * 2));
        final noticeHeight = notice.isEmpty ? 0.0 : painter.height + 4;
        painter.dispose();
        // Session rows are part of the device layout contract. Text scaling
        // must not change the number of rows that fit on a screen; the card
        // content already uses ellipsis/flexible text to adapt inside the
        // configured item height.
        final minimum = sessionMinimumHeight(compact: compact);
        final available = box.maxHeight - padding * 2 - noticeHeight;
        if (sessions.isNotEmpty && available < minimum) {
          return _smallMessage(
            context,
            '${sessions.length} 个会话',
            '${notice.isEmpty ? '' : '$notice。'}请在电脑端调整组件大小。',
          );
        }
        return Padding(
          padding: const EdgeInsets.all(padding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (notice.isNotEmpty) ...[
                Text(
                  notice,
                  style: style.copyWith(color: deskbarColors(context).warning),
                ),
                const SizedBox(height: 4),
              ],
              if (sessions.isEmpty)
                const Expanded(child: _Message('还没有近期会话。'))
              else
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, grid) {
                      final gap = number('gap', 8).clamp(0, 48).toDouble();
                      final automaticColumns = math.max(
                        1,
                        ((grid.maxWidth + gap) /
                                (number('itemWidth', 280).clamp(120, 1000) +
                                    gap))
                            .floor(),
                      );
                      final minimumWidth = options['appearance'] == 'cards'
                          ? 260
                          : 120;
                      final configuredColumns = options['columns'];
                      final columns = configuredColumns is int
                          ? math.min(
                              configuredColumns.clamp(1, 6),
                              math.max(
                                1,
                                ((grid.maxWidth + gap) / (minimumWidth + gap))
                                    .floor(),
                              ),
                            )
                          : automaticColumns;
                      final target = math.max(
                        minimum,
                        number('itemHeight', sessionStandardMinimumHeight),
                      );
                      final rows = math.max(
                        1,
                        ((grid.maxHeight + gap) / (target + gap)).floor(),
                      );
                      final height = options['fitRows'] != false
                          ? (grid.maxHeight - gap * (rows - 1)) / rows
                          : target;
                      return LayoutDebugOverlay(
                        enabled: debugLayout,
                        label:
                            '$columns 列 · 卡片 ${((grid.maxWidth - gap * (columns - 1)) / columns).toStringAsFixed(1)} × ${height.toStringAsFixed(1)} dp · 间距 $gap dp',
                        child: Semantics(
                          label:
                              '${sessions.length} 个近期会话，共 ${data.sessionTotal} 个',
                          child: GridView.builder(
                            key: PageStorageKey('sessions-$id'),
                            padding: EdgeInsets.zero,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  crossAxisSpacing: gap,
                                  mainAxisSpacing: gap,
                                  mainAxisExtent: height,
                                ),
                            itemCount: sessions.length,
                            itemBuilder: (context, index) {
                              final session = sessions[index];
                              final c = deskbarColors(context);
                              final statusColor = session.status == 'running'
                                  ? c.success
                                  : [
                                      'failed',
                                      'interrupted',
                                    ].contains(session.status)
                                  ? c.warning
                                  : c.muted;
                              if (options['appearance'] == 'cards') {
                                return _sessionCard(
                                  context,
                                  session,
                                  data.now,
                                  height,
                                  (grid.maxWidth - gap * (columns - 1)) /
                                      columns,
                                  statusColor,
                                  canOpen,
                                );
                              }
                              final card = Semantics(
                                button: !editing,
                                label:
                                    '${session.title}，${session.statusLabel}',
                                child: Material(
                                  key: ValueKey(
                                    'session-card-$id-${session.id}',
                                  ),
                                  color: Colors.transparent,
                                  borderRadius: BorderRadius.circular(4),
                                  child: InkWell(
                                    onTap: canOpen
                                        ? () => open(
                                            context,
                                            'open_session',
                                            session.id,
                                            session.version,
                                          )
                                        : null,
                                    child: Tooltip(
                                      message: session.title,
                                      child: Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              session.statusLabel,
                                              style: style.copyWith(
                                                color: statusColor,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Flexible(
                                              fit: FlexFit.loose,
                                              child: Text(
                                                session.title,
                                                maxLines: compact ? 1 : 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleMedium,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            if (compact &&
                                                session.project.isNotEmpty)
                                              Text(
                                                session.project,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: style,
                                              ),
                                            if (!compact)
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      session.project,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: style,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    workbenchTime(
                                                      session.updatedAt,
                                                    ),
                                                    style: style,
                                                  ),
                                                ],
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                              return LayoutDebugOverlay(
                                enabled: debugLayout,
                                label:
                                    '卡片 ${((grid.maxWidth - gap * (columns - 1)) / columns).toStringAsFixed(1)} × ${height.toStringAsFixed(1)} dp',
                                top: true,
                                child: card,
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _sessionCard(
    BuildContext context,
    WorkSession session,
    int now,
    double height,
    double width,
    Color statusColor,
    bool canOpen,
  ) {
    final c = deskbarColors(context);
    final running = session.status == 'running';
    final narrow = width < 260;
    final age = math.max(0, now - session.updatedAt);
    final time = age < 60
        ? '刚刚'
        : age < 3600
        ? '${age ~/ 60}分钟前'
        : age < 86400
        ? '${age ~/ 3600}小时前'
        : workbenchTime(session.updatedAt);
    final scale = number('textScale', 1).clamp(1, 2).toDouble();
    // Fit the title and footer in the configured row, including padding and
    // an 8dp gap, without changing how many cards fit on the device.
    final textScale = math.min(
      MediaQuery.textScalerOf(context).scale(14) / 14,
      (height - 28) / (32 * scale * 1.4),
    );
    return Semantics(
      button: !editing,
      label: '${session.title}，${session.statusLabel}',
      child: Material(
        key: ValueKey('session-card-$id-${session.id}'),
        color: running ? c.successBg : c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: running ? c.success.withValues(alpha: .45) : c.line,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: canOpen
              ? () => open(context, 'open_session', session.id, session.version)
              : null,
          child: Container(
            decoration: BoxDecoration(
              border: running
                  ? Border(left: BorderSide(color: c.success, width: 3))
                  : null,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: session.title,
                          child: Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 18 * scale,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (!narrow)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: running ? c.successBg : c.raised,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            session.statusLabel,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 13 * scale,
                              height: 1.4,
                            ),
                          ),
                        ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          session.project,
                          key: ValueKey('session-project-$id-${session.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.muted,
                            fontSize: 14 * scale,
                            height: 1.4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (!narrow)
                        Text(
                          time,
                          key: ValueKey('session-time-$id-${session.id}'),
                          style: TextStyle(
                            color: c.muted,
                            fontSize: 14 * scale,
                            height: 1.4,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
    final maximize = options['iconSize'] == 'max';
    final fixedIconSize = number('iconSize', 56);
    final gapX = number(
      'gapX',
      number('horizontalGap', 8),
    ).clamp(0, 64).toDouble();
    final gapY = number(
      'gapY',
      number('verticalGap', 8),
    ).clamp(0, 64).toDouble();
    final labels = options['labels'] != false;
    final configuredRows = _shortcutRows(options);
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
          final labelHeight = labels
              ? MediaQuery.textScalerOf(context).scale(labelStyle.fontSize!) *
                        (labelStyle.height ?? 1.5) *
                        2 +
                    4
              : 0.0;
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
          final layout = _calculateShortcutLayout(
            count: entries.length,
            width: box.maxWidth,
            height: availableHeight,
            gapX: gapX,
            gapY: gapY,
            labels: labels,
            labelHeight: labelHeight,
            maximize: maximize,
            configuredRows: configuredRows,
            fixedIconSize: fixedIconSize,
          );
          if (box.maxWidth < layout.tileWidth ||
              availableHeight < layout.tileHeight) {
            return _Message(
              '${notice.isEmpty ? '' : '$notice。'}入口区域太小，请在电脑端调整大小。',
            );
          }
          Widget tile(WorkShortcut entry) {
            final c = deskbarColors(context);
            Widget fallback() => Container(
              width: layout.iconSize,
              height: layout.iconSize,
              decoration: BoxDecoration(
                color: c.raised,
                borderRadius: BorderRadius.circular(layout.iconSize * .2),
              ),
              child: Icon(
                entry.kind == 'app'
                    ? Icons.apps_outlined
                    : Icons.language_outlined,
                size: layout.iconSize * .65,
                color: c.muted,
              ),
            );
            return LayoutDebugOverlay(
              enabled: debugLayout,
              label:
                  '单元 ${layout.tileWidth.toStringAsFixed(1)} × ${layout.tileHeight.toStringAsFixed(1)} dp · 图标 ${layout.iconSize.toStringAsFixed(1)} dp',
              top: true,
              child: SizedBox(
                width: layout.tileWidth,
                height: layout.tileHeight,
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
                              width: layout.iconSize,
                              height: layout.iconSize,
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

          final rows = <Widget>[];
          for (var row = 0; row < layout.rows; row++) {
            final start = row * layout.columns;
            if (start >= entries.length) break;
            final end = math.min(start + layout.columns, entries.length);
            final children = <Widget>[];
            for (var index = start; index < end; index++) {
              if (children.isNotEmpty) children.add(SizedBox(width: gapX));
              children.add(tile(entries[index]));
            }
            rows.add(
              SizedBox(
                height: layout.tileHeight,
                child: Row(
                  mainAxisAlignment: _shortcutMainAxisAlignment(alignment),
                  children: children,
                ),
              ),
            );
            if (row + 1 < layout.rows && end < entries.length) {
              rows.add(SizedBox(height: gapY));
            }
          }
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
                      '${layout.columns} 列 × ${layout.rows} 行 · 单元 ${layout.tileWidth.toStringAsFixed(1)} × ${layout.tileHeight.toStringAsFixed(1)} dp · 图标 ${maximize ? '自适应最大 ' : ''}${layout.iconSize.toStringAsFixed(1)} dp · 间距 $gapX / $gapY dp · ${_shortcutAlignmentLabel(alignment)}',
                  child: SingleChildScrollView(
                    key: PageStorageKey('shortcuts-$id'),
                    padding: EdgeInsets.zero,
                    child: Column(children: rows),
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
    final density = _usageDensity(options);
    final alignment = _usageAlignment(options);
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
                  '${u.currency} ${(u.actualCostMicros / 1000000).toStringAsFixed(2)}',
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
            fresh: fresh,
            compact: density == 'compact',
            numberKey: ValueKey('usage-number-$id'),
            status: _status(context, data, sourceId),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        const edge = 8.0;
        final contentWidth = math.max(1.0, box.maxWidth - edge);
        final contentHeight = math.max(1.0, box.maxHeight - edge);
        final tiny = contentHeight < 100;
        final compact = density == 'compact' || tiny;
        final q = quotas.isEmpty ? null : quotas.first;
        final u = usages.isEmpty ? null : usages.first;
        final reset = !api && q!.resetsAt <= data.now;
        final expiredWindow = api && u!.windowEnd <= data.now;
        final fresh =
            online &&
            (data.source(sourceId)?.fresh(data.now) ?? false) &&
            !expiredWindow;
        final numberText = api
            ? '${u!.currency} ${(u.actualCostMicros / 1000000).toStringAsFixed(2)}'
            : reset
            ? '等待刷新'
            : '${q!.remaining.round()}%';
        final numberScale = switch (density) {
          'compact' => .82,
          'standard' => 1.0,
          _ => (contentHeight / (api ? 220 : 200)).clamp(.9, 1.7),
        };
        final numberFontSize = ((api ? 44.0 : 48.0) * numberScale).clamp(
          30.0,
          84.0,
        );
        final title = api
            ? expiredWindow
                  ? '上次实际成本 · 等待刷新'
                  : fresh
                  ? '实际成本'
                  : '上次实际成本'
            : reset
            ? '已到重置时间'
            : fresh
            ? '剩余额度'
            : '上次剩余额度';
        final textTheme = Theme.of(context).textTheme;
        final titleStyle = textTheme.bodySmall?.copyWith(
          height: tiny ? 1.2 : 1.35,
        );
        Widget usageItem(String label, Widget child) => LayoutDebugOverlay(
          enabled: debugLayout,
          label: 'item $label',
          top: true,
          child: child,
        );
        final children = <Widget>[
          usageItem('主指标标题', Text(title, style: titleStyle)),
          const SizedBox(height: 2),
          usageItem(
            '主指标数值',
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                numberText,
                key: ValueKey('usage-number-$id'),
                maxLines: 1,
                style: textTheme.headlineMedium?.copyWith(
                  fontSize: numberFontSize,
                  height: 1.05,
                ),
              ),
            ),
          ),
          if (!fresh) ...[
            const SizedBox(height: 4),
            _status(context, data, sourceId),
          ],
          if (!api && !reset && !compact) ...[
            const SizedBox(height: 8),
            usageItem(
              '额度进度',
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: density == 'fill' ? 8 : 6,
                  value: (q!.remaining / 100).clamp(0, 1),
                ),
              ),
            ),
          ],
        ];
        final fillHeight = density == 'fill' && !tiny;
        final content = Padding(
          padding: const EdgeInsets.all(edge / 2),
          child: SizedBox(
            width: contentWidth,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: fillHeight ? contentHeight : 0,
              ),
              child: Column(
                mainAxisAlignment: fillHeight
                    ? _usageMainAxisAlignment(alignment)
                    : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        );
        return LayoutDebugOverlay(
          enabled: debugLayout,
          label:
              '内容区 ${contentWidth.toStringAsFixed(1)} × ${contentHeight.toStringAsFixed(1)} dp · ${_usageDensityLabel(density)} · ${_usageAlignmentLabel(alignment)}',
          top: true,
          child: Tooltip(
            message: detailMessage,
            preferBelow: false,
            waitDuration: const Duration(milliseconds: 350),
            showDuration: const Duration(seconds: 5),
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: content,
            ),
          ),
        );
      },
    );
  }

  Widget _smallMessage(BuildContext context, String title, String subtitle) =>
      SingleChildScrollView(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
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

/// Labels are painted over measured content; toggling does not change layout.
class LayoutDebugOverlay extends StatelessWidget {
  const LayoutDebugOverlay({
    super.key,
    required this.enabled,
    required this.label,
    required this.child,
    this.top = false,
    this.forceBorder = false,
    this.forceLabel = false,
  });
  final bool enabled, top, forceBorder, forceLabel;
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => _LayoutDebugOverlayStateful(
    enabled: enabled,
    top: top,
    label: label,
    forceBorder: forceBorder,
    forceLabel: forceLabel,
    child: child,
  );
}

class _LayoutDebugOverlayStateful extends StatefulWidget {
  const _LayoutDebugOverlayStateful({
    required this.enabled,
    required this.top,
    required this.label,
    required this.child,
    required this.forceBorder,
    required this.forceLabel,
  });

  final bool enabled, top, forceBorder, forceLabel;
  final String label;
  final Widget child;

  @override
  State<_LayoutDebugOverlayStateful> createState() =>
      _LayoutDebugOverlayStatefulState();
}

class _LayoutDebugOverlayStatefulState
    extends State<_LayoutDebugOverlayStateful> {
  bool hovered = false;

  void _setHovered(bool value) {
    if (hovered == value || !widget.enabled) return;
    setState(() => hovered = value);
  }

  @override
  void didUpdateWidget(covariant _LayoutDebugOverlayStateful oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && hovered) hovered = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final showBorder = hovered || widget.forceBorder;
    final showLabel = hovered || widget.forceLabel;
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Stack(
        // Keep the child's intrinsic height when an item sits in a
        // scrolling column; StackFit.expand would pass an infinite height
        // constraint through to Text during layout.
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (showBorder)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: hovered ? const Color(0x14527bc2) : null,
                    border: Border.all(
                      color: const Color(0xaa527bc2),
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),
          if (showLabel)
            Positioned(
              left: 0,
              right: 0,
              top: widget.top ? 0 : null,
              bottom: widget.top ? null : 0,
              child: IgnorePointer(
                child: ColoredBox(
                  color: const Color(0xb8303e52),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: ExcludeSemantics(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
