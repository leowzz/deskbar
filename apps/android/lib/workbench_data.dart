import 'dart:convert';
import 'dart:typed_data';

class SourceState {
  SourceState(Map<String, dynamic> v)
    : id = v['source_id'] as String,
      health = v['health'] as String,
      message = v['message'] as String,
      observedAt = v['observed_at'] as int,
      freshUntil = v['fresh_until'] as int;
  final String id, health, message;
  final int observedAt, freshUntil;
  bool fresh(int now) => health == 'ready' && freshUntil > now;
}

class WorkSession {
  WorkSession(Map<String, dynamic> v)
    : id = v['session_id'] as String,
      version = v['version'] as String,
      title = v['title'] as String,
      project = v['project'] as String,
      status = v['status'] as String,
      updatedAt = v['updated_at'] as int;
  final String id, version, title, project, status;
  final int updatedAt;
  String get statusLabel => switch (status) {
    'running' => '进行中',
    'completed' => '已完成',
    'failed' => '执行失败',
    'interrupted' => '已中断',
    _ => '状态未知',
  };
}

class WorkQuota {
  WorkQuota(Map<String, dynamic> v)
    : id = (v['id'] as String?) ?? '',
      label = v['label'] as String,
      remaining = (v['remaining_percent'] as num).toDouble(),
      resetsAt = v['resets_at'] as int;
  final String id, label;
  final double remaining;
  final int resetsAt;
}

class WorkApiUsage {
  WorkApiUsage(Map<String, dynamic> v)
    : id = v['id'] as String,
      label = v['label'] as String,
      actualCostMicros = v['actual_cost_micros'] as int,
      currency = v['currency'] as String,
      tokenCount = v['token_count'] as int,
      tpm = v['tpm'] as int,
      windowStart = v['window_start'] as int,
      windowEnd = v['window_end'] as int;
  final String id, label, currency;
  final int actualCostMicros, tokenCount, tpm, windowStart, windowEnd;
}

class WorkShortcut {
  WorkShortcut(Map<String, dynamic> v)
    : id = v['shortcut_id'] as String,
      version = v['version'] as String,
      name = v['name'] as String,
      kind = v['kind'] as String,
      iconBytes = _shortcutIcon(v['icon_png']);
  final String id, version, name, kind;
  final Uint8List? iconBytes;
}

Uint8List? _shortcutIcon(dynamic encoded) {
  if (encoded is! String || encoded.isEmpty || encoded.length > 43692) {
    return null;
  }
  try {
    final bytes = base64Decode(encoded);
    if (bytes.length > 32768 || bytes.length < 24) return null;
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return null;
    }
    final dimensions = ByteData.sublistView(bytes);
    final width = dimensions.getUint32(16), height = dimensions.getUint32(20);
    if (width < 1 || height < 1 || width > 256 || height > 256) return null;
    return bytes;
  } on FormatException {
    return null;
  }
}

class WorkbenchData {
  WorkbenchData(Map<String, dynamic> v)
    : hostId = v['host_id'] as String,
      epoch = v['epoch'] as String,
      revision = v['revision'] as int,
      offset =
          (v['server_time'] as int) -
          ((v['received_at'] as int?) ??
              DateTime.now().millisecondsSinceEpoch ~/ 1000),
      sources = ((v['sources'] as List?) ?? [])
          .map((e) => SourceState(e as Map<String, dynamic>))
          .toList(),
      sessions = ((v['sessions'] as List?) ?? [])
          .map((e) => WorkSession(e as Map<String, dynamic>))
          .toList(),
      quotas = ((v['quotas'] as List?) ?? [])
          .map((e) => WorkQuota(e as Map<String, dynamic>))
          .toList(),
      apiUsage = ((v['api_usage'] as List?) ?? [])
          .map((e) => WorkApiUsage(e as Map<String, dynamic>))
          .toList(),
      shortcuts = ((v['shortcuts'] as List?) ?? [])
          .map((e) => WorkShortcut(e as Map<String, dynamic>))
          .toList(),
      capabilities = List<String>.from((v['capabilities'] as List?) ?? []),
      sessionTotal = (v['session_total'] as int?) ?? 0;
  final String hostId, epoch;
  final int revision, offset, sessionTotal;
  final List<SourceState> sources;
  final List<WorkSession> sessions;
  final List<WorkQuota> quotas;
  final List<WorkApiUsage> apiUsage;
  final List<WorkShortcut> shortcuts;
  final List<String> capabilities;
  int get now => DateTime.now().millisecondsSinceEpoch ~/ 1000 + offset;
  SourceState? source(String id) {
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
  }
}
