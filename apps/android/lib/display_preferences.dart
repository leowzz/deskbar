import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Device display preferences are local and independent of pages, permissions,
/// connection state and remote commands. The Activity owns physical rotation.
class DisplayPreferences extends ChangeNotifier {
  DisplayPreferences({
    bool initialImmersive = true,
    bool initialRotationLocked = false,
  }) : _immersive = initialImmersive,
       _rotationLocked = initialRotationLocked;

  static const _channel = MethodChannel('app.desklet/layout');
  bool _immersive;
  bool _rotationLocked;
  bool _active = false;
  bool _foreground = true;
  bool _touchedImmersive = false;
  bool _touchedRotation = false;
  bool _disposed = false;
  Future<void> _pending = Future.value();
  Future<void>? _restoring;
  String? error;

  bool get immersive => _immersive;
  bool get rotationLocked => _rotationLocked;
  bool get workbenchActive => _active;

  Future<void> restore() => _restoring ??= _restore();

  Future<void> _restore() async {
    try {
      final saved = await _channel.invokeMapMethod<String, dynamic>(
        'loadDisplayPreferences',
      );
      if (_disposed) return;
      if (!_touchedImmersive) {
        _immersive = saved?['immersive'] is bool
            ? saved!['immersive'] as bool
            : true;
      }
      if (!_touchedRotation) _rotationLocked = saved?['rotationLocked'] == true;
      error = null;
      notifyListeners();
    } catch (_) {
      if (_disposed) return;
      error = '未能读取显示设置，当前使用默认设置。';
      notifyListeners();
    }
    await _schedule(_apply);
  }

  Future<void> setImmersive(bool value) {
    _touchedImmersive = true;
    if (_immersive == value) return Future.value();
    _immersive = value;
    error = null;
    notifyListeners();
    return _save();
  }

  Future<void> setRotationLocked(bool value) {
    _touchedRotation = true;
    if (_rotationLocked == value) return Future.value();
    _rotationLocked = value;
    error = null;
    notifyListeners();
    return _save();
  }

  Future<void> setWorkbenchActive(bool value) {
    if (_active == value) return Future.value();
    _active = value;
    notifyListeners();
    return _schedule(_apply);
  }

  Future<void> setForeground(bool value) {
    _foreground = value;
    return _schedule(_apply);
  }

  Future<void> _save() async {
    // A change during startup must preserve the other saved preference.
    await _restoring;
    return _schedule(() async {
      try {
        await _channel.invokeMethod<void>('saveDisplayPreferences', {
          'immersive': _immersive,
          'rotationLocked': _rotationLocked,
        });
      } catch (_) {
        if (!_disposed) {
          error = '显示设置已生效，但未能保存。重启后会恢复原设置。';
          notifyListeners();
        }
      }
      await _apply();
    });
  }

  Future<void> _schedule(Future<void> Function() operation) {
    final next = _pending.then((_) async {
      if (!_disposed) await operation();
    });
    _pending = next.catchError((Object _) {
      if (!_disposed) {
        error = '未能调整屏幕显示，请重试。';
        notifyListeners();
      }
    });
    return _pending;
  }

  Future<void> _apply() async {
    await _channel.invokeMethod<void>('applyDisplayPreferences', {
      'rotationLocked': _active && _rotationLocked,
    });
    if (_disposed) return;
    await SystemChrome.setEnabledSystemUIMode(
      _active && _foreground && _immersive
          ? SystemUiMode.immersiveSticky
          : SystemUiMode.edgeToEdge,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }
}
