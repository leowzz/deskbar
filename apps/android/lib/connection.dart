import 'dart:async';
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

class Connection extends ChangeNotifier {
  static const _channel = MethodChannel('app.desklet/connection');
  static const _events = EventChannel('app.desklet/events');
  ConnectionPhase phase = ConnectionPhase.loading;
  String? hostName;
  String? error;
  bool busy = false;
  bool searching = false;
  List<String> nearby = [];
  DateTime? lastSeen;
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
    await restore();
    if (_disposed) return;
    _reconnect = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_active &&
          hostName != null &&
          !busy &&
          phase != ConnectionPhase.online) {
        unawaited(reconnect());
      }
    });
  }

  Future<void> restore() async {
    try {
      final value = await _channel.invokeMethod<String>('restore');
      hostName = value == null
          ? null
          : (jsonDecode(value) as Map<String, dynamic>)['name'] as String;
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
        hostName =
            (event['snapshot'] as Map<String, dynamic>)['name'] as String;
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
        phase = ConnectionPhase.unpaired;
        error = event['message'] as String?;
    }
    notifyListeners();
  }

  Future<void> pair(String invitation, String name) async {
    final attempt = ++_attempt;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('pair', {
        'invitation': invitation,
        'name': name,
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
      nearby = (jsonDecode(value ?? '[]') as List)
          .map((e) => (e as Map<String, dynamic>)['name'] as String)
          .toSet()
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
      error = null;
      phase = ConnectionPhase.unpaired;
    } on PlatformException catch (e) {
      error = e.message;
    }
    notifyListeners();
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
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
