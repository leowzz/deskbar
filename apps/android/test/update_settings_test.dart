import 'package:deskbar/update_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.deskbar/update');
  final binding = TestDefaultBinaryMessengerBinding.instance;

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('checks, requests install permission, then opens installer', (
    tester,
  ) async {
    var installs = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'version') return '0.1.0';
      if (call.method == 'check') {
        return {'currentVersion': '0.1.0', 'version': '0.1.1'};
      }
      installs++;
      return installs == 1 ? 'permission_required' : 'installer_opened';
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UpdateSettings())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 0.1.1'), findsOneWidget);
    await tester.tap(find.text('安装更新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('允许安装后'), findsOneWidget);
    await tester.tap(find.text('安装更新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已打开安装程序'), findsOneWidget);
    expect(installs, 2);
  });

  testWidgets('failed checks offer retry instead of saying up to date', (
    tester,
  ) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'version') return '0.1.0';
      throw PlatformException(code: 'unavailable', message: '无法检查更新');
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UpdateSettings())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('无法检查更新'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('已是最新版本'), findsNothing);
  });
}
