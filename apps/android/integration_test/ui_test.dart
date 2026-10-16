import 'package:desklet/connection.dart';
import 'package:desklet/workbench_content.dart';
import 'package:desklet/workbench_data.dart';
import 'package:desklet/rawblock.dart';
import '../test/workbench_fixture.dart';
import 'package:desklet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('RawBlock home and camera-free pairing dialog', (tester) async {
    const native = MethodChannel('app.desklet/connection');
    await native.invokeMethod<void>('forget');
    await tester.pumpWidget(const DeskletApp());
    await tester.pumpAndSettle();
    expect(find.text('扫码连接电脑'), findsOneWidget);
    expect(tester.takeException(), isNull);

    const capture = bool.fromEnvironment('DESKLET_SCREENSHOTS');
    if (capture) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await binding.takeScreenshot('rawblock-home');
    }
    await tester.ensureVisible(find.text('粘贴邀请'));
    await tester.tap(find.text('粘贴邀请'));
    await tester.pumpAndSettle();
    expect(find.text('连接邀请'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) {
      await binding.takeScreenshot('rawblock-pairing');
    }
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final connection = Connection()
      ..data = WorkbenchData(snapshot())
      ..phase = ConnectionPhase.online;
    addTearDown(connection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: rawBlockTheme(),
        home: Scaffold(
          appBar: AppBar(title: const Text('Desklet 工作台')),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: WorkbenchContent(connection: connection),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('43%'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) {
      await binding.takeScreenshot('rawblock-workbench');
    }
  });
}
