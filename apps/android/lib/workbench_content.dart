import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'connection.dart';
import 'layout_workspace.dart';
import 'rawblock.dart';
import 'top_notice.dart';
import 'workbench_data.dart';

String workbenchTime(int seconds) {
  if (seconds <= 0) return '未知';
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}';
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
    this.debugLayout = false,
  });
  final Connection connection;
  final String id, type;
  final Map<String, dynamic> options, binding;
  final bool editing, debugLayout;
  final VoidCallback? onEditRequested;
  double number(String key, double fallback) =>
      (options[key] as num?)?.toDouble() ?? fallback;
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
        label:
            '区域 ${box.maxWidth.toStringAsFixed(1)} × ${box.maxHeight.toStringAsFixed(1)} dp',
        top: true,
        child: _body(context),
      ),
    ),
  );

  Widget _body(BuildContext context) {
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
      'shortcuts' => _shortcuts(context, data),
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
        final scale = math.max(
          1.0,
          MediaQuery.textScalerOf(context).scale(14) / 14,
        );
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
        final minimum = (compact ? 88.0 : 140.0) * scale;
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
                      final columns = math.max(
                        1,
                        ((grid.maxWidth + gap) /
                                (number('itemWidth', 280).clamp(120, 1000) +
                                    gap))
                            .floor(),
                      );
                      final target = math.max(
                        minimum,
                        number('itemHeight', compact ? 96 : 148),
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
                              return Semantics(
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
    final iconSize = number('iconSize', 56).clamp(24, 200).toDouble();
    final gapX = number(
      'gapX',
      number('horizontalGap', 8),
    ).clamp(0, 64).toDouble();
    final gapY = number(
      'gapY',
      number('verticalGap', 8),
    ).clamp(0, 64).toDouble();
    final labels = options['labels'] != false;
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
          final tileWidth = math.max(48.0, iconSize + (labels ? 32 : 8));
          final labelHeight = labels
              ? MediaQuery.textScalerOf(context).scale(labelStyle.fontSize!) *
                        (labelStyle.height ?? 1.5) *
                        2 +
                    4
              : 0.0;
          final tileHeight = math.max(48.0, iconSize + labelHeight + 8);
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
          if (box.maxWidth < tileWidth ||
              box.maxHeight - noticeHeight < tileHeight) {
            return _Message(
              '${notice.isEmpty ? '' : '$notice。'}入口区域太小，请在电脑端调整大小。',
            );
          }
          final columns = math.max(
            1,
            ((box.maxWidth + gapX) / (tileWidth + gapX)).floor(),
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
                      '$columns 列 · 单元 ${((box.maxWidth - gapX * (columns - 1)) / columns).toStringAsFixed(1)} × ${tileHeight.toStringAsFixed(1)} dp · 图标 $iconSize dp · 间距 $gapX / $gapY dp',
                  child: GridView.builder(
                    key: PageStorageKey('shortcuts-$id'),
                    padding: EdgeInsets.zero,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: gapX,
                      mainAxisSpacing: gapY,
                      mainAxisExtent: tileHeight,
                    ),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
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
                      return Tooltip(
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
                      );
                    },
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
    void detail() {
      if (editing) return;
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  api ? 'API 用量详情' : 'Codex 额度详情',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                _status(context, data, sourceId),
                const SizedBox(height: 16),
                if (api)
                  for (final u in usages) ...[
                    Text(
                      u.label,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${u.currency} ${(u.actualCostMicros / 1000000).toStringAsFixed(2)}',
                    ),
                    Text(
                      'Token ${_quantity(u.tokenCount)} · TPM ${_quantity(u.tpm)}${u.windowEnd <= data.now ? ' · 上次数据，等待刷新' : ''}',
                    ),
                    Text(
                      '${workbenchTime(u.windowStart)} — ${workbenchTime(u.windowEnd)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                  ]
                else
                  for (final q in quotas) ...[
                    Text(
                      q.label,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      q.resetsAt <= data.now
                          ? '等待刷新'
                          : '${q.remaining.round()}% 剩余',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    Text('${workbenchTime(q.resetsAt)} 重置'),
                    const SizedBox(height: 16),
                  ],
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final small = box.maxHeight < 200;
        final tiny = box.maxHeight < 100;
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
        return InkWell(
          onTap: editing ? null : detail,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  api
                      ? expiredWindow
                            ? '上次实际成本 · 等待刷新'
                            : fresh
                            ? '实际成本'
                            : '上次实际成本'
                      : reset
                      ? '已到重置时间'
                      : fresh
                      ? '剩余额度'
                      : '上次剩余额度',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(height: tiny ? 1.2 : 1.5),
                ),
                Text(
                  numberText,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontSize: tiny
                        ? 30
                        : small
                        ? 32
                        : 44,
                  ),
                ),
                const SizedBox(height: 4),
                if (!fresh) _status(context, data, sourceId),
                if (!api && !reset && !small) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: (q!.remaining / 100).clamp(0, 1),
                  ),
                  const SizedBox(height: 8),
                ],
                if (!small)
                  Text(
                    api
                        ? 'Token ${_quantity(u!.tokenCount)} · TPM ${_quantity(u.tpm)}'
                        : '${workbenchTime(q!.resetsAt)} 重置',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
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
  });
  final bool enabled, top;
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => !enabled
      ? child
      : Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xff527bc2)),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: top ? 0 : null,
              bottom: top ? null : 0,
              child: IgnorePointer(
                child: ColoredBox(
                  color: const Color(0xdd303e52),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Text(
                      label,
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
          ],
        );
}
