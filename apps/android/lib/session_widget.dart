import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'rawblock.dart';
import 'layout_debug.dart';
import 'workbench_data.dart';

/// Owns continuous scrolling and card geometry; the canvas only supplies outer constraints.
class AdaptiveSessions extends StatelessWidget {
  const AdaptiveSessions({
    super.key,
    required this.id,
    required this.sessions,
    required this.visibleCount,
    required this.columns,
    required this.now,
    required this.notice,
    required this.onOpen,
    this.debugLayout = false,
  });
  final String id, notice;
  final List<WorkSession> sessions;
  final int visibleCount, now;
  final int? columns;
  final ValueChanged<WorkSession>? onOpen;
  final bool debugLayout;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final c = deskbarColors(context);
      final gap = (math.min(box.maxWidth, box.maxHeight) / 30).clamp(4.0, 12.0);
      final edge = math.min(4.0, math.min(box.maxWidth, box.maxHeight) / 8);
      final width = math.max(1.0, box.maxWidth - edge * 2);
      final maxColumns = math.max(1, ((width + gap) / (140 + gap)).floor());
      final columns =
          (this.columns ?? math.max(1, ((width + gap) / (260 + gap)).floor()))
              .clamp(1, math.min(6, maxColumns))
              .toInt();
      return Padding(
        padding: EdgeInsets.all(edge),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (notice.isNotEmpty)
              SizedBox(
                height: math.min(24, box.maxHeight * .2),
                child: Tooltip(
                  message: notice,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      notice,
                      style: TextStyle(color: c.warning, fontSize: 12),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: sessions.isEmpty
                  ? const Center(child: Text('还没有近期会话。'))
                  : LayoutBuilder(
                      builder: (context, grid) {
                        // Visible count sets the row height; every session stays in the scroll list.
                        final count = math.min(visibleCount, sessions.length);
                        final rows = (count / columns).ceil();
                        final height = math.max(
                          60.0,
                          (grid.maxHeight - gap * (rows - 1)) / rows,
                        );
                        final cardWidth =
                            (width - gap * (columns - 1)) / columns;
                        return GridView.builder(
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
                          itemBuilder: (context, index) => LayoutDebugOverlay(
                            enabled: debugLayout,
                            top: true,
                            label:
                                '卡片 ${cardWidth.toStringAsFixed(1)} × ${height.toStringAsFixed(1)} dp',
                            child: _card(
                              context,
                              sessions[index],
                              cardWidth,
                              height,
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

  Widget _card(
    BuildContext context,
    WorkSession session,
    double width,
    double height,
  ) {
    final c = deskbarColors(context);
    final running = session.status == 'running';
    final color = running
        ? c.success
        : ['failed', 'interrupted'].contains(session.status)
        ? c.warning
        : c.muted;
    final scale = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
      1.0,
      height < 100 ? 1.15 : 1.4,
    );
    final font = (math.min(width / 15, height / 6)).clamp(16.0, 22.0);
    final metadataLines =
        ((height - 16 - font * 1.25 * scale) / (15 * scale + 4)).floor().clamp(
          0,
          3,
        );
    final wide = width >= 240;
    final repo = session.repo.isNotEmpty ? session.repo : session.project;
    final repository = [
      repo,
      if (session.branch.isNotEmpty) session.branch,
    ].where((s) => s.isNotEmpty).join(' · ');
    final model = [
      session.model,
      if (session.model.isNotEmpty) session.reasoningEffort,
    ].where((s) => s.isNotEmpty).join(' · ');
    final age = math.max(0, now - session.updatedAt);
    final time = age < 60
        ? '刚刚'
        : age < 3600
        ? '${age ~/ 60}分钟前'
        : age < 86400
        ? '${age ~/ 3600}小时前'
        : workbenchTime(session.updatedAt);
    final info = [
      session.title,
      session.statusLabel,
      if (repo.isNotEmpty) '仓库：$repo',
      if (session.project.isNotEmpty && session.project != repo)
        '项目：${session.project}',
      if (session.branch.isNotEmpty) '分支：${session.branch}',
      if (model.isNotEmpty) '模型：$model',
      '更新：${workbenchTime(session.updatedAt)}（$time）',
    ].join('\n');
    Widget detail(String text, String key) => Text(
      text,
      key: ValueKey('session-$key-$id-${session.id}'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: c.muted, fontSize: 12, height: 1.25),
    );
    final metadata = <Widget>[
      if (metadataLines > 0)
        Row(
          children: [
            Expanded(child: detail(repository, 'project')),
            if (wide) ...[const SizedBox(width: 8), detail(time, 'time')],
          ],
        ),
      if (metadataLines > 1 && model.isNotEmpty) detail(model, 'model'),
      if (!wide && metadataLines > (model.isEmpty ? 1 : 2))
        detail(time, 'time'),
    ];
    final titleLines =
        height - 16 - metadata.length * (15 * scale + 4) >=
            font * 1.25 * scale * 2
        ? 2
        : 1;
    return Semantics(
      button: onOpen != null,
      label: info,
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
          onTap: onOpen == null ? null : () => onOpen!(session),
          child: Tooltip(
            message: info,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: width < 180 ? 8 : 12,
                vertical: 8,
              ),
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                session.title,
                                maxLines: titleLines,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: font,
                                  height: 1.25,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (width >= 320)
                            Text(
                              session.statusLabel,
                              style: TextStyle(color: color, fontSize: 12),
                            )
                          else
                            Icon(Icons.circle, size: 7, color: color),
                        ],
                      ),
                    ),
                    for (final line in metadata) ...[
                      const SizedBox(height: 4),
                      line,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
