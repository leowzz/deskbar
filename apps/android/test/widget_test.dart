import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desklet/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.desklet/connection'),
          (call) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.desklet/events'),
          (call) async => null,
        );
  });
  for (final scenario in [
    (const Size(360, 640), 1.0),
    (const Size(360, 640), 1.8),
    (const Size(800, 360), 1.4),
  ]) {
    testWidgets(
      'camera-free pairing at ${scenario.$1}, text scale ${scenario.$2}',
      (tester) async {
        tester.view.physicalSize = scenario.$1;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scenario.$2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(const DeskletApp());
        await tester.pumpAndSettle();
        expect(find.text('粘贴邀请'), findsOneWidget);
        await tester.ensureVisible(find.text('粘贴邀请'));
        await tester.tap(find.text('粘贴邀请'));
        await tester.pumpAndSettle();
        expect(find.text('连接邀请'), findsOneWidget);
        expect(find.text('这台设备的名称'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
