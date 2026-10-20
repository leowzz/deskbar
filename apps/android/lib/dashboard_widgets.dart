import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'connection.dart';
import 'rawblock.dart';
import 'workbench_data.dart';

/// Local time and actual connection state; no shared data permission needed.
class WorkbenchStatusBar extends StatefulWidget {
  const WorkbenchStatusBar({
    super.key,
    required this.connection,
    required this.options,
    this.onTheme,
    this.onSettings,
    this.editing = false,
  });
  final Connection connection;
  final Map<String, dynamic> options;
  final VoidCallback? onTheme, onSettings;
  final bool editing;
  @override
  State<WorkbenchStatusBar> createState() => _WorkbenchStatusBarState();
}

class _WorkbenchStatusBarState extends State<WorkbenchStatusBar> {
  late final Timer clock;
  @override
  void initState() {
    super.initState();
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.options['showClock'] != false) setState(() {});
    });
  }

  @override
  void dispose() {
    clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = deskbarColors(context);
    final options = widget.options;
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final time =
        '${two(now.month)}/${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}'
        '${options['showSeconds'] != false ? ':${two(now.second)}' : ''} '
        '星期${['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1]}';
    final online = widget.connection.phase == ConnectionPhase.online;
    final label = options['label'] as String? ?? 'DeskBar';
    final clockText = Text(
      time,
      key: const ValueKey('status-bar-clock'),
      maxLines: 1,
      style: TextStyle(
        color: c.muted,
        fontSize: 16,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return ColoredBox(
      color: c.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < 900;
            final actions = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (options['showThemeButton'] != false)
                  IconButton(
                    tooltip: '切换主题',
                    onPressed: widget.editing ? null : widget.onTheme,
                    icon: Icon(
                      Theme.of(context).brightness == Brightness.dark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                    ),
                  ),
                if (options['showConnection'] != false) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.circle,
                    size: 8,
                    color: online ? c.success : c.warning,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    online
                        ? '实时连接'
                        : widget.connection.phase == ConnectionPhase.connecting
                        ? '正在连接'
                        : '电脑离线',
                    style: TextStyle(color: c.muted),
                  ),
                ],
                if (options['showSettingsButton'] != false)
                  IconButton(
                    tooltip: '设置',
                    onPressed: widget.editing ? null : widget.onSettings,
                    icon: const Icon(Icons.settings_outlined),
                  ),
              ],
            );
            final brand = Row(
              children: [
                if (label.isNotEmpty) ...[
                  Icon(
                    Icons.space_dashboard_outlined,
                    size: 23,
                    color: c.success,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            );
            final row = Row(
              children: [
                Expanded(child: brand),
                actions,
              ],
            );
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (narrow)
                      row
                    else
                      Row(
                        children: [
                          Expanded(child: brand),
                          if (options['showClock'] != false)
                            Expanded(
                              child: Center(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: clockText,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: actions,
                            ),
                          ),
                        ],
                      ),
                    if (narrow && options['showClock'] != false) clockText,
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class QuotaSidebar extends StatelessWidget {
  const QuotaSidebar({
    super.key,
    required this.quota,
    required this.now,
    required this.fresh,
    this.status,
  });
  final WorkQuota quota;
  final int now;
  final bool fresh;
  final Widget? status;
  @override
  Widget build(BuildContext context) {
    final c = deskbarColors(context);
    final expired = quota.resetsAt <= now;
    final reset = DateTime.fromMillisecondsSinceEpoch(
      quota.resetsAt * 1000,
    ).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final remaining = Duration(seconds: math.max(0, quota.resetsAt - now));
    final countdown = expired
        ? '等待刷新'
        : remaining.inDays > 0
        ? '${remaining.inDays}天${remaining.inHours % 24}时'
        : '${remaining.inHours}时${remaining.inMinutes % 60}分';
    return LayoutBuilder(
      builder: (context, box) {
        final horizontal = box.maxWidth > box.maxHeight * 1.5;
        Widget metric(
          String label,
          String value,
          double size, {
          Color? color,
        }) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(label, style: TextStyle(color: c.muted, fontSize: 16)),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: size,
                    height: 1.15,
                    color: color ?? c.text,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        );
        final metrics = [
          metric(
            expired
                ? '已到重置时间'
                : fresh
                ? '剩余额度'
                : '上次剩余额度',
            expired ? '等待刷新' : '${quota.remaining.round()}%',
            60,
          ),
          metric(
            '重置时间',
            '${two(reset.month)}/${two(reset.day)}'
                '${horizontal ? ' ' : '\n'}${two(reset.hour)}:${two(reset.minute)}',
            32,
          ),
          metric('剩余时间', countdown, 30, color: c.chart),
        ];
        if (horizontal) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < metrics.length; i++) ...[
                if (i > 0) VerticalDivider(width: 1, color: c.line),
                Expanded(child: SingleChildScrollView(child: metrics[i])),
              ],
            ],
          );
        }
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                metrics[0],
                Divider(height: 16, color: c.line),
                metrics[1],
                Divider(height: 16, color: c.line),
                metrics[2],
                if (!fresh && status != null) status!,
              ],
            ),
          ),
        );
      },
    );
  }
}
