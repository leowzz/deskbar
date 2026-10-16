import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deskbar/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? savedHost;
  setUp(() {
    savedHost = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.deskbar/layout'),
          (call) async => call.method == 'loadTheme' ? 'light' : null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.deskbar/connection'),
          (call) async => call.method == "restore" ? savedHost : null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.deskbar/events'),
          (call) async => null,
        );
  });
  for (final scenario in [
    (const Size(360, 640), 1.0),
    (const Size(360, 640), 1.8),
    (const Size(800, 360), 1.4),
    (const Size(480, 280), 1.8),
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
        await tester.pumpWidget(const DeskBarApp());
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
    testWidgets(
      'paired computer and disconnect dialog at ${scenario.$1}, text scale ${scenario.$2}',
      (tester) async {
        savedHost = '{"name":"工作用的电脑名字比较长，也应完整显示"}';
        tester.view.physicalSize = scenario.$1;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scenario.$2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(const DeskBarApp());
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsNothing);
        expect(find.byTooltip('添加组件'), findsNothing);
        expect(find.text('编辑页面与组件'), findsNothing);
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        expect(find.text('全屏显示'), findsOneWidget);
        expect(find.text('锁定旋转'), findsOneWidget);
        expect(find.text('工作用的电脑名字比较长，也应完整显示'), findsOneWidget);
        await tester.ensureVisible(find.text('断开电脑'));
        await tester.tap(find.text('断开电脑'));
        await tester.pumpAndSettle();
        expect(find.text('断开这台电脑？'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('取消'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
