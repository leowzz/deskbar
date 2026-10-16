import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'connection.dart';
import 'rawblock.dart';
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
  });
  final Connection connection;
  final String id, type;
  final Map<String, dynamic> options, binding;
  final bool editing;
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
    if (context.mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
    final c = deskletColors(context);
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
    final resource = binding['resourceId'];
    final sessions = data.sessions
        .where((s) => resource == null || resource == '' || s.id == resource)
        .toList();
    if (source == null) return const _Message('请在电脑的设备卡片中开启「近期会话」共享。');
    if (resource != null && resource != '' && sessions.isEmpty) {
      return const _Message('绑定的会话已不在共享范围。请在组件设置中选择其他会话。');
    }
    final canOpen =
        !editing &&
        online &&
        !connection.opening &&
        data.capabilities.contains('open_session') &&
        source.fresh(data.now);
    return LayoutBuilder(
      builder: (context, box) {
        final compact = options['density'] == 'compact';
        final scale = math.max(
          1.0,
          MediaQuery.textScalerOf(context).scale(14) / 14,
        );
        final tight = compact && box.maxHeight < 240 * scale;
        final padding = tight ? 8.0 : 12.0;
        final headerGap = tight ? 4.0 : 8.0;
        final count = '显示 ${sessions.length} 个 / 共 ${data.sessionTotal} 个';
        final status = _sourceStatusLabel(data, 'codex.sessions');
        final c = deskletColors(context);
        final style = Theme.of(context).textTheme.bodySmall!;
        final statusStyle = style.copyWith(
          color: !online || !source.fresh(data.now) ? c.warning : c.muted,
        );
        final permitted =
            editing ||
            data.capabilities.contains('open_session') ||
            sessions.isEmpty;
        const permission = '在电脑端开启「允许在电脑上打开」后可点击会话。';
        final width = math.max(0.0, box.maxWidth - padding * 2);
        final span = TextSpan(
          style: style,
          children: [
            TextSpan(text: '${sessions.length} / ${data.sessionTotal} 个会话 · '),
            TextSpan(text: status, style: statusStyle),
          ],
        );
        final combined = TextPainter(
          text: span,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout(maxWidth: width);
        final oneLine = tight && !combined.didExceedMaxLines;
        double textHeight(String text) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: width);
          final height = painter.height;
          painter.dispose();
          return height;
        }

        final headerHeight =
            (oneLine
                ? combined.height
                : textHeight(count) + textHeight(status)) +
            (permitted ? 0 : textHeight(permission));
        combined.dispose();
        final minimum = (compact ? 88.0 : 140.0) * scale;
        final available =
            box.maxHeight - padding * 2 - headerHeight - headerGap;
        if (available < 0 || sessions.isNotEmpty && available < minimum) {
          return _smallMessage(
            context,
            count,
            '$status${permitted ? '' : '。$permission'}。扩大组件或临时铺满以查看完整会话。',
          );
        }
        return Padding(
          padding: EdgeInsets.all(padding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (oneLine)
                Text.rich(span)
              else ...[
                Text(count, style: style),
                Text(status, style: statusStyle),
              ],
              if (!permitted) Text(permission, style: style),
              SizedBox(height: headerGap),
              if (sessions.isEmpty)
                const Expanded(child: _Message('还没有近期会话。'))
              else
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, grid) {
                      final gap = number('gap', 12).clamp(0, 48).toDouble();
                      final columns = math.max(
                        1,
                        ((grid.maxWidth + gap) /
                                (number('itemWidth', 280) + gap))
                            .floor(),
                      );
                      final compact = options['density'] == 'compact';
                      final scale =
                          MediaQuery.textScalerOf(context).scale(14) / 14;
                      final minimum =
                          (compact ? 88.0 : 140.0) * math.max(1, scale);
                      final target = math.max(
                        minimum,
                        number('itemHeight', compact ? 96 : 148),
                      );
                      final rows = math.max(
                        1,
                        ((grid.maxHeight + gap) / (target + gap)).floor(),
                      );
                      final height = options['fitRows'] != false
                          ? math.max(
                              minimum,
                              (grid.maxHeight - gap * (rows - 1)) / rows,
                            )
                          : target;
                      return GridView.builder(
                        key: PageStorageKey('sessions-$id'),
                        padding: EdgeInsets.zero,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: gap,
                          mainAxisSpacing: gap,
                          mainAxisExtent: height,
                        ),
                        itemCount: sessions.length,
                        itemBuilder: (context, index) {
                          final s = sessions[index];
                          final c = deskletColors(context);
                          final statusColor = s.status == 'running'
                              ? c.success
                              : ['failed', 'interrupted'].contains(s.status)
                              ? c.warning
                              : c.muted;
                          return Semantics(
                            button: !editing,
                            label: '${s.title}，${s.statusLabel}',
                            child: Material(
                              key: ValueKey('session-card-$id-${s.id}'),
                              color: c.raised,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: BorderSide(color: c.line),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: canOpen
                                    ? () => open(
                                        context,
                                        'open_session',
                                        s.id,
                                        s.version,
                                      )
                                    : null,
                                child: Tooltip(
                                  message: s.title,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          s.statusLabel,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: statusColor,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Expanded(
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              s.title,
                                              maxLines: compact ? 1 : 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleMedium,
                                            ),
                                          ),
                                        ),
                                        if (s.project.isNotEmpty)
                                          Text(
                                            s.project,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        if (!compact)
                                          Text(
                                            workbenchTime(s.updatedAt),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
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
            ? '绑定的入口已不在共享范围，请在组件设置中重新选择。'
            : '还没有共享入口。在电脑端添加入口，并向这台设备开启共享。',
      );
    }
    final iconSize = number('iconSize', 56).clamp(24, 200).toDouble();
    final gapX = number(
      'gapX',
      number('horizontalGap', 12),
    ).clamp(0, 64).toDouble();
    final gapY = number(
      'gapY',
      number('verticalGap', 12),
    ).clamp(0, 64).toDouble();
    final labels = options['labels'] != false;
    final canOpen =
        !editing &&
        online &&
        !connection.opening &&
        data.capabilities.contains('open_shortcut');
    return Padding(
      padding: EdgeInsets.all(iconSize <= 40 ? 8 : 12),
      child: LayoutBuilder(
        builder: (context, box) {
          final tileWidth = math.max(48.0, iconSize + (labels ? 40 : 16));
          final tileHeight = math.max(
            48.0,
            iconSize +
                (labels ? MediaQuery.textScalerOf(context).scale(40) : 0) +
                4,
          );
          if (box.maxWidth < tileWidth || box.maxHeight < tileHeight) {
            return const _Message('图标放不下。请扩大组件或点击标题栏临时铺满。');
          }
          final columns = math.max(
            1,
            ((box.maxWidth + gapX) / (tileWidth + gapX)).floor(),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!online || !data.capabilities.contains('open_shortcut'))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    !online ? '电脑离线 · 暂时无法打开' : '请在电脑端开启「允许在电脑上打开」。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Expanded(
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
                    final s = entries[index];
                    final c = deskletColors(context);
                    return Tooltip(
                      message: s.name,
                      child: Semantics(
                        label: s.name,
                        button: !editing,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: canOpen
                              ? () => open(
                                  context,
                                  'open_shortcut',
                                  s.id,
                                  s.version,
                                )
                              : null,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: iconSize,
                                height: iconSize,
                                decoration: BoxDecoration(
                                  color: c.raised,
                                  borderRadius: BorderRadius.circular(
                                    iconSize * .22,
                                  ),
                                  border: Border.all(color: c.line),
                                ),
                                child: Icon(
                                  s.kind == 'app'
                                      ? Icons.apps_outlined
                                      : Icons.language_outlined,
                                  size: iconSize * .5,
                                  color: c.text,
                                ),
                              ),
                              if (labels) ...[
                                const SizedBox(height: 4),
                                Text(
                                  s.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: c.text),
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
        final c = deskletColors(context);
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
            padding: EdgeInsets.all(tiny ? 4 : 12),
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
                _status(context, data, sourceId),
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
                if (!editing)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '查看详情',
                      style: TextStyle(fontSize: 12, color: c.selectedText),
                    ),
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
        padding: const EdgeInsets.all(12),
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
      padding: const EdgeInsets.all(12),
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
