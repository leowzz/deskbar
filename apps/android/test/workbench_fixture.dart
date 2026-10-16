const shortcutIconPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGMwsAv6D8IMMAYAOewG/V2y8+cAAAAASUVORK5CYII=';

Map<String, dynamic> snapshot({bool expired = false}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return {
    'host_id': 'host',
    'epoch': 'epoch',
    'revision': 1,
    'server_time': now,
    'sources': [
      for (final id in ['codex.sessions', 'codex.quota'])
        {
          'source_id': id,
          'health': 'ready',
          'message': '',
          'observed_at': now - 3,
          'fresh_until': now + 20,
        },
    ],
    'sessions': [
      {
        'session_id': 'session',
        'version': 'version',
        'title': '一个比较长的真实工作任务标题，需要在大字号和窄屏下保持可读',
        'project': 'Desklet',
        'status': 'running',
        'updated_at': now,
      },
    ],
    'session_total': 1,
    'quotas': [
      {
        'id': 'weekly',
        'label': '每周额度',
        'remaining_percent': 42.5,
        'resets_at': now + (expired ? -1 : 300),
      },
    ],
    'shortcuts': [
      {
        'shortcut_id': 'shortcut',
        'version': 'shortcut-version',
        'name': '常用应用入口名称很长也能换行',
        'kind': 'app',
        'icon_png': shortcutIconPng,
      },
    ],
    'capabilities': ['open_session', 'open_shortcut'],
  };
}
