import 'workbench_fixture.dart';
import 'dart:convert';
import 'package:deskbar/connection.dart';
import 'package:deskbar/rawblock.dart';
import 'package:deskbar/workbench_content.dart';
import 'package:deskbar/workbench_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<dynamic, dynamic>? sent;
  late Map<String, String> response;
  PlatformException? commandError;
  setUp(() {
    sent = null;
    response = {'status': 'succeeded', 'message': '电脑已接受打开请求'};
    commandError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.deskbar/connection'),
          (call) async {
            if (call.method == 'command') {
              sent = call.arguments as Map;
              if (commandError != null) throw commandError!;
              return jsonEncode(response);
            }
            return null;
          },
        );
  });
  for (final scenario in [
    (const Size(360, 640), 1.0),
    (const Size(360, 640), 1.8),
    (const Size(800, 360), 1.4),
  ]) {
    testWidgets('live workbench fits ${scenario.$1} at ${scenario.$2}', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.$1;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scenario.$2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final c = Connection()
        ..data = WorkbenchData(snapshot())
        ..phase = ConnectionPhase.online;
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: WorkbenchContent(connection: c),
            ),
          ),
        ),
      );
      expect(find.text('43%'), findsOneWidget);
      final session = find.text('一个比较长的真实工作任务标题，需要在大字号和窄屏下保持可读');
      await tester.ensureVisible(session);
      await tester.tap(session);
      await tester.pumpAndSettle();
      expect(sent?['action'], 'open_session');
      expect(sent?['target_id'], 'session');
      expect(sent?['target_version'], 'version');
      expect(sent?.containsKey('target'), isFalse);
      expect(find.text('电脑已接受打开请求'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final scenario in [
    ('failed', const Size(360, 640), Brightness.light),
    ('rejected', const Size(800, 360), Brightness.dark),
    ('unknown', const Size(320, 480), Brightness.dark),
    ('transport', const Size(360, 640), Brightness.light),
  ]) {
    testWidgets('${scenario.$1} open shows a temporary notice at the top', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.$2;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, left: 18, right: 18);
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      const message = '未能打开，请先查看电脑后重试';
      response = {'status': scenario.$1, 'message': message};
      if (scenario.$1 == 'transport') {
        commandError = PlatformException(code: 'COMMAND', message: message);
      }
      final c = Connection()
        ..data = WorkbenchData(snapshot())
        ..phase = ConnectionPhase.online;
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(scenario.$3),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: 180,
                child: WorkbenchWidgetBody(
                  connection: c,
                  id: 'icons',
                  type: 'shortcuts',
                  options: const {'iconSize': 48},
                  binding: const {},
                ),
              ),
            ),
          ),
        ),
      );
      final body = tester.getRect(find.byType(WorkbenchWidgetBody));
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      final notice = tester.getRect(find.text(message));
      expect(notice.top, greaterThanOrEqualTo(24));
      expect(notice.top, lessThan(80));
      expect(notice.left, greaterThanOrEqualTo(18));
      expect(notice.right, lessThanOrEqualTo(scenario.$2.width - 18));
      expect(tester.getRect(find.byType(WorkbenchWidgetBody)), body);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text(message), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('expired quota waits and offline actions do not submit', (
    tester,
  ) async {
    final c = Connection()
      ..data = WorkbenchData(snapshot(expired: true))
      ..phase = ConnectionPhase.offline;
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: rawBlockTheme(),
        home: Scaffold(
          body: SingleChildScrollView(child: WorkbenchContent(connection: c)),
        ),
      ),
    );
    expect(find.text('等待刷新'), findsOneWidget);
    expect(find.text('100%'), findsNothing);
    expect(await c.open('open_session', 'session', 'version'), contains('离线'));
    expect(sent, isNull);
    c.phase = ConnectionPhase.online;
    c.data!.capabilities.clear();
    expect(
      await c.open('open_shortcut', 'shortcut', 'shortcut-version'),
      contains('允许'),
    );
    expect(sent, isNull);
  });
  testWidgets(
    'shortcut renders the shared PNG at its chosen size and blank long press never opens',
    (tester) async {
      final c = Connection()
        ..data = WorkbenchData(snapshot())
        ..phase = ConnectionPhase.online;
      addTearDown(c.dispose);
      var editingRequests = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                height: 160,
                child: WorkbenchWidgetBody(
                  connection: c,
                  id: 'icons',
                  type: 'shortcuts',
                  options: const {'iconSize': 72},
                  binding: const {},
                  onEditRequested: () => editingRequests++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Image)), const Size(72, 72));
      final area = tester.getRect(find.byType(WorkbenchWidgetBody));
      await tester.longPressAt(area.topRight + const Offset(-8, 8));
      await tester.pumpAndSettle();
      expect(editingRequests, 1);
      expect(sent, isNull);
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      expect(sent?['target_id'], 'shortcut');
      expect(sent?['target_version'], 'shortcut-version');
      expect(find.text('电脑已接受打开请求'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
