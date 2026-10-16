import 'package:flutter/material.dart';
import 'connection.dart';
import 'rawblock.dart';
import 'workbench_data.dart';

class WorkbenchContent extends StatelessWidget {
  const WorkbenchContent({super.key, required this.connection});
  final Connection connection;
  Future<void> _open(
    BuildContext context,
    String action,
    String id,
    String version,
  ) async {
    final message = await connection.open(action, id, version);
    if (context.mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = connection.data;
    final online = connection.phase == ConnectionPhase.online;
    final text = Theme.of(context).textTheme;
    if (data == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 24),
        child: Text('正在等待电脑共享内容。请在电脑的设备卡片中选择会话、额度和快捷入口。'),
      );
    }
    final now = data.now;
    final sessions = data.source('codex.sessions');
    final quota = data.source('codex.quota');
    final canOpen = online && !connection.opening;
    Widget heading(String title, String subtitle) => Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.headlineSmall),
          const SizedBox(height: 8),
          Text(subtitle, style: text.bodySmall),
        ],
      ),
    );
    Widget sourceStatus(SourceState? source) {
      if (source == null) return const Text('请在电脑的设备卡片中开启共享。');
      final fresh = source.fresh(now);
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!online || !fresh)
              Text(
                !online
                    ? '电脑离线 · 显示上次数据'
                    : source.message.isNotEmpty
                    ? source.message
                    : '数据已过期，等待刷新',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            if (source.observedAt > 0)
              Text('上次更新 ${_time(source.observedAt)}', style: text.bodySmall),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (connection.opening)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('正在电脑上打开…'),
          ),
        heading('Codex 额度', '账户额度独立刷新'),
        sourceStatus(quota),
        if (data.quotas.isEmpty && quota != null)
          const Text('暂时没有可用额度，请在电脑上确认 Codex 已登录。'),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 600 ? 2 : 1;
            final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: data.quotas.map((q) {
                final reset = q.resetsAt <= now;
                final fresh = online && (quota?.fresh(now) ?? false) && !reset;
                return SizedBox(
                  width: width,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(q.label, style: text.titleMedium),
                          const SizedBox(height: 16),
                          Text(
                            reset ? '等待刷新' : '${q.remaining.round()}%',
                            style: text.headlineMedium,
                          ),
                          Text(
                            reset
                                ? '已到重置时间'
                                : fresh
                                ? '剩余额度'
                                : '上次剩余额度',
                          ),
                          const SizedBox(height: 16),
                          if (!reset)
                            LinearProgressIndicator(
                              value: (q.remaining / 100).clamp(0, 1),
                              minHeight: 8,
                            ),
                          const SizedBox(height: 12),
                          Text(
                            '${_time(q.resetsAt)} 重置',
                            style: text.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
        heading('快捷入口', '在电脑上打开常用网页和应用'),
        if (data.shortcuts.isEmpty) const Text('还没有共享入口。在电脑端添加入口，并向这台设备开启共享。'),
        if (data.shortcuts.isNotEmpty &&
            !data.capabilities.contains('open_shortcut'))
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text('请在电脑端开启「允许在电脑上打开」。'),
          ),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: data.shortcuts
              .map(
                (s) => OutlinedButton(
                  onPressed:
                      canOpen && data.capabilities.contains('open_shortcut')
                      ? () => _open(context, 'open_shortcut', s.id, s.version)
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(s.name),
                        Text(
                          s.kind == 'app' ? '应用' : '网页',
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        heading(
          '近期会话',
          '显示 ${data.sessions.length} 个 / 共 ${data.sessionTotal} 个 · 点击回到电脑继续',
        ),
        sourceStatus(sessions),
        if (data.sessions.isEmpty && sessions != null) const Text('还没有近期会话。'),
        if (data.sessions.isNotEmpty &&
            !data.capabilities.contains('open_session'))
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text('开启电脑端的「允许在电脑上打开」后，即可点击会话。'),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 780
                ? 3
                : constraints.maxWidth >= 530
                ? 2
                : 1;
            final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: data.sessions
                  .map(
                    (s) => SizedBox(
                      width: width,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.all(20),
                          alignment: Alignment.centerLeft,
                        ),
                        onPressed:
                            canOpen &&
                                data.capabilities.contains('open_session') &&
                                (sessions?.fresh(now) ?? false)
                            ? () => _open(
                                context,
                                'open_session',
                                s.id,
                                s.version,
                              )
                            : null,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.statusLabel,
                              style: TextStyle(
                                fontSize: 14,
                                color: s.status == 'running'
                                    ? rawSuccess
                                    : Colors.black,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(s.title, style: text.titleMedium),
                            if (s.project.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(s.project, style: text.bodySmall),
                            ],
                            const SizedBox(height: 8),
                            Text(_time(s.updatedAt), style: text.bodySmall),
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }
}

String _time(int seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}';
}
