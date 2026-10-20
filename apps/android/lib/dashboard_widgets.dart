import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'connection.dart';
import 'layout_debug.dart';
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
    return ColoredBox(
      color: c.surface,
      child: LayoutBuilder(
        builder: (context, box) {
          final width = math.max(160.0, box.maxWidth);
          final showLabel =
              label.isNotEmpty &&
              (width >= 640 || box.maxHeight >= 88 && width >= 320);
          final clockBreakpoint =
              640 *
              math.max(1.0, MediaQuery.textScalerOf(context).scale(16) / 16);
          final secondLine =
              width < 480 || width < clockBreakpoint && box.maxHeight >= 88;
          Widget clockText({bool short = false}) => Tooltip(
            message: time,
            child: Text(
              short ? '${two(now.hour)}:${two(now.minute)}' : time,
              key: const ValueKey('status-bar-clock'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.muted,
                fontSize: 16,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          );
          final connectionLabel = online
              ? '实时连接'
              : widget.connection.phase == ConnectionPhase.connecting
              ? '正在连接'
              : '电脑离线';
          final row = SizedBox(
            height: math.max(48, MediaQuery.textScalerOf(context).scale(30)),
            child: CustomMultiChildLayout(
              delegate: _StatusBarLayout(),
              children: [
                if (showLabel)
                  LayoutId(
                    id: 'label',
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (!secondLine && options['showClock'] != false)
                  LayoutId(
                    id: 'clock',
                    child: clockText(short: width < clockBreakpoint),
                  ),
                LayoutId(
                  id: 'actions',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (options['showConnection'] != false)
                        Tooltip(
                          message: connectionLabel,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.circle,
                                size: 8,
                                color: online ? c.success : c.warning,
                              ),
                              if (width >= 480) ...[
                                const SizedBox(width: 8),
                                Text(
                                  connectionLabel,
                                  style: TextStyle(color: c.muted),
                                ),
                              ],
                              const SizedBox(width: 8),
                            ],
                          ),
                        ),
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
                      if (options['showSettingsButton'] != false)
                        IconButton(
                          tooltip: '设置',
                          onPressed: widget.editing ? null : widget.onSettings,
                          icon: const Icon(Icons.settings_outlined),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
          return Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: width,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      row,
                      if (secondLine && options['showClock'] != false)
                        clockText(short: box.maxHeight < 88),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Reserve the same space on both sides of the clock, regardless of label length.
class _StatusBarLayout extends MultiChildLayoutDelegate {
  _StatusBarLayout();

  @override
  void performLayout(Size size) {
    final actions = layoutChild('actions', BoxConstraints.loose(size));
    positionChild(
      'actions',
      Offset(size.width - actions.width, (size.height - actions.height) / 2),
    );
    var labelWidth = size.width - actions.width - 8;
    if (hasChild('clock')) {
      final clock = layoutChild(
        'clock',
        BoxConstraints(
          maxWidth: math.max(0, size.width - 2 * (actions.width + 8)),
          maxHeight: size.height,
        ),
      );
      positionChild(
        'clock',
        Offset(
          (size.width - clock.width) / 2,
          (size.height - clock.height) / 2,
        ),
      );
      labelWidth = math.min(labelWidth, (size.width - clock.width) / 2 - 8);
    }
    if (hasChild('label')) {
      final label = layoutChild(
        'label',
        BoxConstraints(
          maxWidth: math.max(0, labelWidth),
          maxHeight: size.height,
        ),
      );
      positionChild('label', Offset(0, (size.height - label.height) / 2));
    }
  }

  @override
  bool shouldRelayout(_StatusBarLayout oldDelegate) => false;
}

class QuotaSidebar extends StatelessWidget {
  const QuotaSidebar({
    super.key,
    required this.quota,
    required this.now,
    required this.fresh,
    this.status,
    this.compact = false,
    this.debugLayout = false,
    this.numberKey,
  });
  final WorkQuota quota;
  final int now;
  final bool fresh, compact, debugLayout;
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
    return AdaptiveMetrics(
      debugLayout: debugLayout,
      primary: MetricValue(
        label: expired
            ? '已到重置时间'
            : fresh
            ? '剩余额度'
            : '上次剩余额度',
        value: expired ? '等待刷新' : '${quota.remaining.round()}%',
        valueKey: numberKey,
      ),
      secondary: [
        MetricValue(
          label: '重置时间',
          value: '$date $time',
          valueKey: const ValueKey('quota-reset'),
        ),
        MetricValue(
          label: '剩余时间',
          value: countdown,
          valueKey: const ValueKey('quota-countdown'),
          color: c.chart,
        ),
      ],
      summary: expired ? '等待额度刷新' : '$date $time 重置 · $countdown',
      status: fresh ? null : status,
    );
  }
}

class MetricValue {
  const MetricValue({
    required this.label,
    required this.value,
    this.valueKey,
    this.color,
  });
  final String label, value;
  final Key? valueKey;
  final Color? color;
}

/// Measures the inner region after padding and stale-data status, then chooses
/// a layout. Quota and API metrics never depend on a user-configured density.
class AdaptiveMetrics extends StatelessWidget {
  const AdaptiveMetrics({
    super.key,
    required this.primary,
    required this.secondary,
    this.summary,
    this.status,
    this.debugLayout = false,
  });
  final MetricValue primary;
  final List<MetricValue> secondary;
  final String? summary;
  final bool debugLayout;
  final Widget? status;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, outer) {
      final edge = (math.min(outer.maxWidth, outer.maxHeight) / 20).clamp(
        2.0,
        12.0,
      );
      return Padding(
        padding: EdgeInsets.all(edge),
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final scale =
                      (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
                        1.0,
                        1.5,
                      );
                  final horizontal =
                      box.maxWidth >= 440 && box.maxWidth > box.maxHeight * 1.6;
                  // Keep the two details side by side even in a narrow sidebar;
                  // their text scales to the cells instead of forcing a summary.
                  final split =
                      box.maxWidth >= 144 && box.maxHeight >= 140 * scale;
                  final stacked =
                      !horizontal && !split && box.maxHeight >= 260 * scale;
                  final full =
                      horizontal && box.maxHeight >= 88 * scale ||
                      stacked ||
                      split;
                  Widget metric(MetricValue value, {bool main = false}) =>
                      LayoutDebugOverlay(
                        enabled: debugLayout,
                        top: true,
                        label: 'item ${value.label}',
                        child: _AdaptiveMetric(value: value, primary: main),
                      );
                  Widget divider({bool vertical = false}) => vertical
                      ? VerticalDivider(
                          width: 16,
                          color: deskbarColors(context).line,
                        )
                      : Divider(height: 16, color: deskbarColors(context).line);
                  if (!full) {
                    return Column(
                      children: [
                        Expanded(child: metric(primary, main: true)),
                        if (box.maxHeight >= 72 * scale)
                          SizedBox(
                            height: math.min(34 * scale, box.maxHeight * .3),
                            child: Center(
                              child: Text(
                                summary ??
                                    secondary
                                        .map((m) => '${m.label} ${m.value}')
                                        .join(' · '),
                                key: summary == null
                                    ? null
                                    : const ValueKey('quota-reset-summary'),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: deskbarColors(context).muted,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  }
                  if (horizontal) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 5, child: metric(primary, main: true)),
                        for (final value in secondary) ...[
                          divider(vertical: true),
                          Expanded(flex: 4, child: metric(value)),
                        ],
                      ],
                    );
                  }
                  if (stacked) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 5, child: metric(primary, main: true)),
                        for (final value in secondary) ...[
                          divider(),
                          Expanded(flex: 4, child: metric(value)),
                        ],
                      ],
                    );
                  }
                  return Column(
                    children: [
                      Expanded(flex: 5, child: metric(primary, main: true)),
                      divider(),
                      Expanded(
                        flex: 4,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < secondary.length; i++) ...[
                              if (i > 0) divider(vertical: true),
                              Expanded(child: metric(secondary[i])),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (status != null)
              SizedBox(
                height: math.min(32, outer.maxHeight * .2),
                child: ClipRect(
                  child: SingleChildScrollView(
                    child: DefaultTextStyle.merge(
                      style: const TextStyle(fontSize: 12),
                      child: status!,
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

class _AdaptiveMetric extends StatelessWidget {
  const _AdaptiveMetric({required this.value, required this.primary});
  final MetricValue value;
  final bool primary;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final c = deskbarColors(context);
      final labelFont = (box.maxWidth / 7).clamp(10.0, 13.0);
      final labelHeight =
          MediaQuery.textScalerOf(context).scale(labelFont) * 1.3;
      final font = (math.min(
        box.maxWidth * (primary ? .34 : .2),
        box.maxHeight * .52,
      )).clamp(primary ? 24.0 : 14.0, primary ? 88.0 : 40.0);
      return Semantics(
        label: '${value.label}：${value.value}',
        child: Column(
          children: [
            if (box.maxHeight >= labelHeight + 28) ...[
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value.label,
                  maxLines: 1,
                  style: TextStyle(
                    color: c.muted,
                    fontSize: labelFont,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value.valueKey == const ValueKey('quota-reset') &&
                            box.maxWidth < 260
                        ? value.value.replaceFirst(' ', '\n')
                        : value.value,
                    key: value.valueKey,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: font,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                      color: value.color ?? c.text,
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
