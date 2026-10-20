import 'dart:async';
import 'workbench_data.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum ConnectionPhase {
  loading,
  unpaired,
  connecting,
  online,
  offline,
  approval,
}

class NearbyComputer {
  NearbyComputer({
    required this.hostId,
    required this.name,
    required this.invitation,
  });

  factory NearbyComputer.fromJson(Map<String, dynamic> value) {
    final endpoint = value['endpoint'] as String?;
    final session = value['session'] as String?;
    final secret = value['secret'] as String?;
    final host = value['host_id'] as String?;
    final pin = value['pin'] as String?;
    final expires = value['expires'];
    if (endpoint == null ||
        session == null ||
        secret == null ||
        host == null ||
        pin == null ||
        expires is! num) {
      throw const FormatException('自动发现返回的电脑信息不完整');
    }
    final uri = Uri(
      scheme: 'deskbar',
      host: 'pair',
      queryParameters: {
        'v': '1',
        'host': host,
        'name': value['name'] as String? ?? 'DeskBar 连接助手',
        'pin': pin,
        'session': session,
        'secret': secret,
        'expires': expires.toInt().toString(),
        'endpoint': endpoint,
      },
    ).toString();
    return NearbyComputer(
      hostId: host,
      name: value['name'] as String? ?? 'DeskBar 连接助手',
      invitation: uri,
    );
  }

  final String hostId;
  final String name;
  final String invitation;
}

class Connection extends ChangeNotifier {
  static const _channel = MethodChannel('app.deskbar/connection');
  static const _events = EventChannel('app.deskbar/events');
  ConnectionPhase phase = ConnectionPhase.loading;
  String? hostName;
  String? error;
  bool busy = false;
  bool searching = false;
  List<NearbyComputer> nearby = [];
  DateTime? lastSeen;
  WorkbenchData? data;
  bool opening = false;
  Timer? _clock;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnect;
  bool _active = true;
  bool _disposed = false;
  int _attempt = 0;

  Future<void> start() async {
    _subscription = _events.receiveBroadcastStream().listen(
      _event,
      onError: (_) {
        error = '未能读取连接状态，请重试';
        notifyListeners();
      },
    );
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (data != null) notifyListeners();
    });
    await restore();
    if (_disposed) return;
    if (hostName == null) unawaited(discover());
    _reconnect = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!_active || busy) return;
      if (hostName != null && phase != ConnectionPhase.online) {
        unawaited(reconnect());
      } else if (hostName == null && !searching) {
        unawaited(discover());
      }
    });
  }

  Future<void> restore() async {
    try {
      final value = await _channel.invokeMethod<String>('restore');
      final saved = value == null
          ? null
          : jsonDecode(value) as Map<String, dynamic>;
      hostName = saved?['name'] as String?;
      data = saved?['snapshot'] == null
          ? null
          : WorkbenchData(saved!['snapshot'] as Map<String, dynamic>);
      phase = hostName == null
          ? ConnectionPhase.unpaired
          : ConnectionPhase.connecting;
      error = null;
      if (hostName != null) await reconnect();
    } on PlatformException catch (e) {
      phase = ConnectionPhase.offline;
      error = e.message ?? '无法读取连接，请重试';
    }
    notifyListeners();
  }

  void _event(dynamic value) {
    final event = jsonDecode(value as String) as Map<String, dynamic>;
    switch (event['type']) {
      case 'paired':
        phase = ConnectionPhase.connecting;
        hostName = event['name'] as String;
        error = null;
      case 'snapshot':
        final snapshot = event['snapshot'] as Map<String, dynamic>;
        data = WorkbenchData(snapshot);
        hostName = snapshot['name'] as String;
        lastSeen = DateTime.now();
        phase = ConnectionPhase.online;
        error = null;
      case 'approval':
        phase = ConnectionPhase.approval;
      case 'connecting':
        phase = ConnectionPhase.connecting;
      case 'offline':
        phase = ConnectionPhase.offline;
        error = event['message'] as String?;
      case 'revoked':
        hostName = null;
        lastSeen = null;
        data = null;
        phase = ConnectionPhase.unpaired;
        error = event['message'] as String?;
    }
    notifyListeners();
  }

  Future<String> defaultDeviceName() async {
    try {
      final name = await _channel.invokeMethod<String>('deviceName');
      if (name != null && name.trim().isNotEmpty) return name.trim();
    } on PlatformException {
      // Model information is optional; pairing remains available.
    } on MissingPluginException {
      // Previews and older native bridges may not provide model information.
    }
    return 'Android 工作台';
  }

  Future<void> pair(String invitation, [String? name]) async {
    final attempt = ++_attempt;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final deviceName = name ?? await defaultDeviceName();
      if (attempt != _attempt || _disposed) return;
      await _channel.invokeMethod<void>('pair', {
        'invitation': invitation,
        'name': deviceName,
      });
    } on PlatformException catch (e) {
      if (attempt != _attempt) return;
      error = e.message ?? '连接未完成，请重试';
      phase = hostName == null
          ? ConnectionPhase.unpaired
          : ConnectionPhase.offline;
    } finally {
      if (attempt == _attempt) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> cancel() async {
    _attempt++;
    await _channel.invokeMethod<void>('cancel');
    busy = false;
    phase = hostName == null
        ? ConnectionPhase.unpaired
        : ConnectionPhase.offline;
    notifyListeners();
  }

  Future<void> reconnect() async {
    if (!_active) return;
    try {
      await _channel.invokeMethod<void>('connect');
    } on PlatformException catch (e) {
      error = e.message;
      phase = ConnectionPhase.offline;
      notifyListeners();
    }
  }

  Future<void> discover() async {
    if (searching) return;
    searching = true;
    error = null;
    notifyListeners();
    try {
      final value = await _channel.invokeMethod<String>('discover');
      final seen = <String>{};
      NearbyComputer? parse(dynamic value) {
        try {
          return NearbyComputer.fromJson(value as Map<String, dynamic>);
        } on FormatException {
          return null;
        }
      }

      nearby = (jsonDecode(value ?? '[]') as List)
          .map(parse)
          .whereType<NearbyComputer>()
          .where((computer) => seen.add(computer.hostId))
          .toList();
    } on PlatformException catch (e) {
      error = e.message;
    } finally {
      searching = false;
      notifyListeners();
    }
  }

  Future<void> forget() async {
    _attempt++;
    try {
      await _channel.invokeMethod<void>('forget');
      hostName = null;
      lastSeen = null;
      data = null;
      error = null;
      phase = ConnectionPhase.unpaired;
    } on PlatformException catch (e) {
      error = e.message;
    }
    notifyListeners();
  }

  Future<String?> open(String action, String id, String version) async {
    if (opening) return '请等待上一次操作完成';
    final snapshot = data;
    if (!_active || phase != ConnectionPhase.online || snapshot == null) {
      return '电脑离线，连接后才能打开';
    }
    if (!snapshot.capabilities.contains(action)) return '请在电脑上允许这台设备打开内容';
    final attempt = _attempt;
    opening = true;
    notifyListeners();
    try {
      final value = await _channel.invokeMethod<String>('command', {
        'host_id': snapshot.hostId,
        'host_epoch': snapshot.epoch,
        'action': action,
        'target_id': id,
        'target_version': version,
        'expires_at': snapshot.now + 8,
      });
      if (attempt != _attempt) return '操作已结束，请查看电脑';
      final result = jsonDecode(value!) as Map<String, dynamic>;
      if (result['status'] == 'succeeded') return null;
      return result['message'] as String;
    } on PlatformException catch (e) {
      return e.message ?? '结果未知，请先查看电脑；不会自动重试';
    } finally {
      opening = false;
      notifyListeners();
    }
  }

  Future<void> reportDisplay(Map<String, dynamic> report) async {
    if (phase != ConnectionPhase.online) return;
    try {
      await _channel.invokeMethod<void>('display', report);
    } on PlatformException {
      // Rendering remains available; the next heartbeat retries the report.
    } on MissingPluginException {
      // The desktop preview and widget tests have no Android transport.
    }
  }

  Future<void> setActive(bool active) async {
    _active = active;
    if (active) {
      if (hostName != null) await reconnect();
    } else {
      _attempt++;
      await _channel.invokeMethod<void>('pause');
      busy = false;
      if (hostName != null) {
        phase = ConnectionPhase.offline;
      } else if (phase == ConnectionPhase.approval) {
        phase = ConnectionPhase.unpaired;
      }
      notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _attempt++;
    _reconnect?.cancel();
    _clock?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
