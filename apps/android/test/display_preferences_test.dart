import 'dart:async';

import 'package:desklet/display_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> stored;
  late List<MethodCall> calls;
  late List<MethodCall> systemCalls;
  late int commands;
  setUp(() {
    stored = {};
    calls = [];
    systemCalls = [];
    commands = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('app.desklet/layout'),
      (call) async {
        calls.add(call);
        if (call.method == 'loadDisplayPreferences') return stored;
        if (call.method == 'saveDisplayPreferences') {
          stored = Map<String, dynamic>.from(call.arguments as Map);
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      systemCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('app.desklet/connection'),
      (call) async {
        if (call.method == 'command') commands++;
        return null;
      },
    );
  });

  test(
    'defaults to immersive with free sensor rotation and applies only to active workbench',
    () async {
      final display = DisplayPreferences();
      addTearDown(display.dispose);
      await display.restore();
      expect(display.immersive, true);
      expect(display.rotationLocked, false);
      expect(systemCalls.last.arguments, 'SystemUiMode.edgeToEdge');
      await display.setWorkbenchActive(true);
      expect(systemCalls.last.arguments, 'SystemUiMode.immersiveSticky');
      final applied = calls
          .where((call) => call.method == 'applyDisplayPreferences')
          .last;
      expect((applied.arguments as Map)['rotationLocked'], false);
      expect(
        systemCalls.any(
          (call) => call.method == 'SystemChrome.setPreferredOrientations',
        ),
        false,
      );
      expect(commands, 0);
    },
  );

  test(
    'rotation lock and immersive choices restore after controller restart',
    () async {
      final display = DisplayPreferences();
      await display.restore();
      await display.setWorkbenchActive(true);
      await display.setRotationLocked(true);
      await display.setImmersive(false);
      expect(stored, {'immersive': false, 'rotationLocked': true});
      expect((calls.last.arguments as Map)['rotationLocked'], true);
      display.dispose();
      final restarted = DisplayPreferences();
      addTearDown(restarted.dispose);
      await restarted.restore();
      await restarted.setWorkbenchActive(true);
      expect(restarted.immersive, false);
      expect(restarted.rotationLocked, true);
      expect(systemCalls.last.arguments, 'SystemUiMode.edgeToEdge');
      await restarted.setRotationLocked(false);
      expect((calls.last.arguments as Map)['rotationLocked'], false);
      expect(commands, 0);
    },
  );

  test(
    'foreground resume reapplies immersive and disconnect restores system bars',
    () async {
      final display = DisplayPreferences();
      addTearDown(display.dispose);
      await display.setWorkbenchActive(true);
      await display.setRotationLocked(true);
      await display.setForeground(false);
      expect(systemCalls.last.arguments, 'SystemUiMode.edgeToEdge');
      expect((calls.last.arguments as Map)['rotationLocked'], true);
      await display.setForeground(true);
      expect(systemCalls.last.arguments, 'SystemUiMode.immersiveSticky');
      await display.setWorkbenchActive(false);
      expect(systemCalls.last.arguments, 'SystemUiMode.edgeToEdge');
      expect((calls.last.arguments as Map)['rotationLocked'], false);
      expect(display.rotationLocked, true);
      expect(commands, 0);
    },
  );

  test('late restore cannot replace a newer display choice', () async {
    final loaded = Completer<Map<String, dynamic>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app.desklet/layout'), (
          call,
        ) async {
          if (call.method == 'loadDisplayPreferences') return loaded.future;
          return null;
        });
    final display = DisplayPreferences();
    addTearDown(display.dispose);
    final restoring = display.restore();
    final immersive = display.setImmersive(false);
    final rotation = display.setRotationLocked(true);
    loaded.complete({'immersive': true, 'rotationLocked': false});
    await Future.wait([restoring, immersive, rotation]);
    expect(display.immersive, false);
    expect(display.rotationLocked, true);
  });

  test(
    'a startup change preserves the untouched persisted preference',
    () async {
      final loaded = Completer<Map<String, dynamic>>();
      Map<String, dynamic>? written;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app.desklet/layout'), (
            call,
          ) async {
            if (call.method == 'loadDisplayPreferences') return loaded.future;
            if (call.method == 'saveDisplayPreferences') {
              written = Map<String, dynamic>.from(call.arguments as Map);
            }
            return null;
          });
      final display = DisplayPreferences();
      addTearDown(display.dispose);
      final restoring = display.restore();
      final changing = display.setImmersive(false);
      loaded.complete({'immersive': true, 'rotationLocked': true});
      await Future.wait([restoring, changing]);
      expect(written, {'immersive': false, 'rotationLocked': true});
      expect(display.rotationLocked, true);
    },
  );

  test(
    'rapid changes preserve the last requested choice without remote commands',
    () async {
      final display = DisplayPreferences();
      addTearDown(display.dispose);
      await display.setWorkbenchActive(true);
      await Future.wait([
        display.setRotationLocked(true),
        display.setImmersive(false),
        display.setRotationLocked(false),
        display.setImmersive(true),
      ]);
      expect(stored, {'immersive': true, 'rotationLocked': false});
      expect(systemCalls.last.arguments, 'SystemUiMode.immersiveSticky');
      expect((calls.last.arguments as Map)['rotationLocked'], false);
      expect(commands, 0);
    },
  );

  test(
    'failed persistence leaves the display usable and reports restart impact',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app.desklet/layout'), (
            call,
          ) async {
            if (call.method == 'saveDisplayPreferences') {
              throw PlatformException(code: 'disk_full');
            }
            return null;
          });
      final display = DisplayPreferences();
      addTearDown(display.dispose);
      await display.setWorkbenchActive(true);
      await display.setImmersive(false);
      expect(display.immersive, false);
      expect(display.error, contains('重启后'));
      expect(systemCalls.last.arguments, 'SystemUiMode.edgeToEdge');
      expect(commands, 0);
    },
  );
}
