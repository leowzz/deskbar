import 'dart:convert';
import 'package:desklet/connection.dart';
import 'package:desklet/layout_repository.dart';
import 'package:desklet/layout_workspace.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native display preferences persist and select full sensor rotation',
    (tester) async {
      const preferences = MethodChannel('app.desklet/layout');
      final old = await preferences.invokeMapMethod<String, dynamic>(
        'loadDisplayPreferences',
      );
      addTearDown(() async {
        await preferences.invokeMethod<void>(
          'saveDisplayPreferences',
          old ?? {'immersive': true, 'rotationLocked': false},
        );
        await preferences.invokeMethod<Object?>('applyDisplayPreferences', {
          'rotationLocked': old?['rotationLocked'] == true,
        });
      });
      await preferences.invokeMethod<void>('saveDisplayPreferences', {
        'immersive': true,
        'rotationLocked': false,
      });
      final unlocked = await preferences.invokeMapMethod<String, dynamic>(
        'applyDisplayPreferences',
        {'rotationLocked': false},
      );
      expect(unlocked?['requestedOrientation'], 10); // Android FULL_SENSOR.
      await preferences.invokeMethod<void>('saveDisplayPreferences', {
        'immersive': false,
        'rotationLocked': true,
      });
      expect(
        await preferences.invokeMapMethod<String, dynamic>(
          'loadDisplayPreferences',
        ),
        {'immersive': false, 'rotationLocked': true},
      );
      final locked = await preferences.invokeMapMethod<String, dynamic>(
        'applyDisplayPreferences',
        {'rotationLocked': true},
      );
      expect(locked?['requestedOrientation'], isIn([0, 1, 8, 9]));
      await expectLater(
        preferences.invokeMethod<void>('saveDisplayPreferences', {
          'immersive': true,
        }),
        throwsA(isA<PlatformException>()),
      );
    },
  );
  testWidgets(
    'native TLS pinning, approval, encrypted restore, WSS and revocation',
    (tester) async {
      const invitation = String.fromEnvironment('DESKLET_INVITE');
      expect(
        invitation,
        isNotEmpty,
        reason: 'Start the Rust Android fixture first',
      );
      const native = MethodChannel('app.desklet/connection');
      const preferences = MethodChannel('app.desklet/layout');
      final oldTheme = await preferences.invokeMethod<String>('loadTheme');
      await preferences.invokeMethod<void>('saveTheme', {'theme': 'dark'});
      expect(await preferences.invokeMethod<String>('loadTheme'), 'dark');
      await expectLater(
        preferences.invokeMethod<void>('saveTheme', {'theme': 'invalid'}),
        throwsA(isA<PlatformException>()),
      );
      await preferences.invokeMethod<void>('saveTheme', {
        'theme': oldTheme ?? 'light',
      });
      final repository = LayoutRepository();
      final original = (await repository.load()).document;
      final workspace = LayoutWorkspace(document: original)..beginEdit();
      final page = workspace.addPage(name: '原生保存测试')!;
      final first = workspace.addWidget('sessions')!;
      final second = workspace.addWidget('sessions')!;
      workspace.updateWidget(first, options: {'itemWidth': 360});
      await repository.save(workspace.document);
      final restoredLayout = (await LayoutRepository().load()).document;
      expect(restoredLayout.activePageId, page);
      expect(restoredLayout.activePage.widgets.map((w) => w.id), [
        first,
        second,
      ]);
      expect(restoredLayout.activePage.widgets.first.options['itemWidth'], 360);
      await repository.save(original);
      workspace.dispose();
      await native.invokeMethod<void>('forget');
      final connection = Connection();
      await connection.start();
      addTearDown(connection.dispose);

      // A wrong pin must fail before sending the one-time secret.
      final uri = Uri.parse(invitation);
      final params = Map<String, List<String>>.from(uri.queryParametersAll);
      params['pin'] = ['sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='];
      await connection.pair(
        uri.replace(queryParameters: params).toString(),
        '连接测试屏幕',
      );
      expect(connection.hostName, isNull);
      expect(connection.error, contains('核验'));

      await connection.pair(invitation, '连接测试屏幕');
      Future<void> until(bool Function() predicate) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!predicate() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(predicate(), isTrue, reason: connection.error);
      }

      await until(() => connection.phase == ConnectionPhase.online);
      final stored = jsonDecode(
        (await native.invokeMethod<String>('restore'))!,
      );
      expect(stored['name'], 'Desklet 连接测试');
      await until(() => connection.data?.sessions.isNotEmpty ?? false);
      expect(connection.data!.sessions.single.title, '验证工作台连接');
      expect(connection.data!.quotas.single.remaining, 42);
      expect(connection.data!.shortcuts.single.name, '测试入口');
      expect(connection.data!.shortcuts.single.iconBytes, isNotNull);
      expect(connection.data!.apiUsage.single.actualCostMicros, 1250000);
      final cached =
          jsonDecode((await native.invokeMethod<String>('restore'))!) as Map;
      expect(cached.containsKey('token'), isFalse);
      expect((cached['snapshot'] as Map)['sessions'], isNotEmpty);
      expect((cached['snapshot'] as Map)['api_usage'], isNotEmpty);
      expect(
        ((cached['snapshot'] as Map)['shortcuts'] as List).single['icon_png'],
        isNotNull,
      );
      final data = connection.data!;
      try {
        await native.invokeMethod<String>('command', {
          'host_id': data.hostId,
          'host_epoch': data.epoch,
          'action': 'run_shell',
          'target_id': 'anything',
          'target_version': 'anything',
          'expires_at': data.now + 8,
        });
        fail('Unknown remote actions must be rejected');
      } on PlatformException catch (e) {
        expect(e.message, contains('不支持'));
      }

      await connection.setActive(false);
      await connection.setActive(true);
      await until(() => connection.phase == ConnectionPhase.online);
      await until(() => connection.data?.capabilities.isEmpty ?? false);
      expect(connection.data!.sessions, isEmpty);
      expect(connection.data!.quotas, isEmpty);
      expect(connection.data!.shortcuts, isEmpty);
      expect(connection.data!.apiUsage, isEmpty);
      final cleared =
          jsonDecode((await native.invokeMethod<String>('restore'))!) as Map;
      expect((cleared['snapshot'] as Map)['sessions'], isEmpty);
      expect((cleared['snapshot'] as Map)['api_usage'], isEmpty);
      expect(connection.hostName, isNotNull);
      await until(() => connection.phase == ConnectionPhase.unpaired);
      expect(connection.data, isNull);
      expect(await native.invokeMethod<String>('restore'), isNull);
      expect(connection.error, contains('移除'));
    },
  );
}
