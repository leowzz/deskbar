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
    this.compact = false,
    this.numberKey,
  });
  final WorkQuota quota;
  final int now;
  final bool fresh, compact;
  final Widget? status;
  final Key? numberKey;

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
        ? '已到期'
        : remaining.inDays > 0
        ? '${remaining.inDays}天${remaining.inHours % 24}时'
        : '${remaining.inHours}时${remaining.inMinutes % 60}分';
    final date = '${two(reset.month)}/${two(reset.day)}';
    final time = '${two(reset.hour)}:${two(reset.minute)}';
    return LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final horizontal =
            box.maxWidth >= 460 && box.maxWidth > box.maxHeight * 1.3;
        final stacked = !compact && !horizontal && box.maxHeight >= 260 * scale;
        Widget metric(
          String label,
          String value,
          double size, {
          Key? valueKey,
          Color? color,
        }) => _QuotaMetric(
          label: label,
          value: value,
          fontSize: size,
          valueKey: valueKey,
          color: color,
        );
        final primary = metric(
          expired
              ? '已到重置时间'
              : fresh
              ? '剩余额度'
              : '上次剩余额度',
          expired ? '等待刷新' : '${quota.remaining.round()}%',
          compact ? 48 : 64,
          valueKey: numberKey,
        );
        final resetMetric = metric(
          '重置时间',
          stacked || (!horizontal && box.maxWidth < 360)
              ? '$date\n$time'
              : '$date $time',
          30,
          valueKey: const ValueKey('quota-reset'),
        );
        final countdownMetric = metric(
          '剩余时间',
          countdown,
          30,
          color: c.chart,
          valueKey: const ValueKey('quota-countdown'),
        );
        final details = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: resetMetric),
            VerticalDivider(width: 16, color: c.line),
            Expanded(child: countdownMetric),
          ],
        );
        Widget content;
        if (compact || box.maxHeight < 120 * scale) {
          content = Column(
            children: [
              Expanded(child: primary),
              if (box.maxHeight >= 64 * scale)
                Text(
                  expired ? '等待额度刷新' : '$date $time 重置 · $countdown',
                  key: const ValueKey('quota-reset-summary'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
            ],
          );
        } else if (horizontal) {
          content = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: primary),
              VerticalDivider(width: 16, color: c.line),
              Expanded(flex: 8, child: details),
            ],
          );
        } else if (stacked) {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: primary),
              Divider(height: 16, color: c.line),
              Expanded(flex: 4, child: resetMetric),
              Divider(height: 16, color: c.line),
              Expanded(flex: 4, child: countdownMetric),
            ],
          );
        } else {
          content = Column(
            children: [
              Expanded(flex: 5, child: primary),
              Divider(height: 12, color: c.line),
              Expanded(flex: 4, child: details),
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Expanded(child: content),
              if (!fresh && status != null)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.min(48, box.maxHeight * .25),
                  ),
                  child: SingleChildScrollView(child: status),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _QuotaMetric extends StatelessWidget {
  const _QuotaMetric({
    required this.label,
    required this.value,
    required this.fontSize,
    this.valueKey,
    this.color,
  });
  final String label, value;
  final double fontSize;
  final Key? valueKey;
  final Color? color;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final c = deskbarColors(context);
      final labelHeight = MediaQuery.textScalerOf(context).scale(14) * 1.4;
      return Semantics(
        label: '$label：$value',
        child: Column(
          children: [
            if (box.maxHeight >= labelHeight + 24) ...[
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.muted, fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 4),
            ],
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    key: valueKey,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: fontSize,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                      color: color ?? c.text,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
