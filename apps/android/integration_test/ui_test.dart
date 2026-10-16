import 'package:desklet/connection.dart';
import 'package:desklet/display_preferences.dart';
import 'package:desklet/layout_workspace.dart';
import 'package:desklet/rawblock.dart';
import 'package:desklet/workbench_canvas.dart';
import 'package:desklet/workbench_data.dart';
import '../test/workbench_fixture.dart';
import 'package:desklet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('silver and graphite, pairing and multi-page workbench editor', (
    tester,
  ) async {
    const native = MethodChannel('app.desklet/connection');
    const local = MethodChannel('app.desklet/layout');
    await native.invokeMethod<void>('forget');
    await local.invokeMethod<void>('saveTheme', {'theme': 'light'});
    await tester.pumpWidget(const DeskletApp());
    await tester.pumpAndSettle();
    expect(find.text('扫码连接电脑'), findsOneWidget);
    expect(tester.takeException(), isNull);
    const capture = bool.fromEnvironment('DESKLET_SCREENSHOTS');
    if (capture) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await binding.takeScreenshot('silver-home');
    }
    await tester.tap(find.byTooltip('切换暗色主题'));
    await tester.pumpAndSettle();
    expect(await local.invokeMethod<String>('loadTheme'), 'dark');
    if (capture) await binding.takeScreenshot('graphite-home');
    await tester.tap(find.byTooltip('切换浅色主题'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('粘贴邀请'));
    await tester.tap(find.text('粘贴邀请'));
    await tester.pumpAndSettle();
    expect(find.text('连接邀请'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) await binding.takeScreenshot('silver-pairing');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    final value = snapshot();
    final original = (value['sessions'] as List).first as Map<String, dynamic>;
    value['sessions'] = [
      for (var i = 0; i < 12; i++)
        {
          ...original,
          'session_id': 'session-$i',
          'title': [
            '完善工作台页面和组件',
            '检查 API 用量采集',
            '发布前验证与回归测试',
            '整理设计与交互文档',
          ][i % 4],
          'status': ['running', 'completed', 'interrupted', 'unknown'][i % 4],
        },
    ];
    value['session_total'] = 48;
    final connection = Connection()
      ..hostName = '工作电脑'
      ..data = WorkbenchData(value)
      ..phase = ConnectionPhase.online;
    final workspace = LayoutWorkspace();
    final display = DisplayPreferences();
    addTearDown(display.dispose);
    addTearDown(connection.dispose);
    addTearDown(workspace.dispose);
    Future<void> render(Brightness brightness) async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: rawBlockTheme(brightness),
          home: Scaffold(
            body: SafeArea(
              child: WorkbenchCanvas(
                connection: connection,
                workspace: workspace,
                displayPreferences: display,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await display.setWorkbenchActive(true);
      await tester.pumpAndSettle();
    }

    await render(Brightness.light);
    expect(find.text('43%'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) await binding.takeScreenshot('silver-workbench');
    expect(find.byTooltip('编辑布局'), findsNothing);
    expect(find.byIcon(Icons.fullscreen), findsNothing);
    expect(find.text('1'), findsNothing);
    await tester.drag(
      find.byType(PageView),
      Offset(-tester.getSize(find.byType(PageView)).width * .8, 0),
    );
    await tester.pumpAndSettle();
    expect(workspace.activePage.name, '任务');
    expect(tester.takeException(), isNull);
    if (capture) await binding.takeScreenshot('silver-sessions');
    final background = find.byKey(
      const ValueKey('page-edit-background-page-tasks'),
    );
    await tester.longPressAt(
      tester.getTopLeft(background) + const Offset(.25, .25),
    );
    await tester.pumpAndSettle();
    final pageBefore = workspace.activePage.id;
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(workspace.activePage.id, pageBefore);
    if (capture) await binding.takeScreenshot('silver-editor');
    await tester.tap(find.byTooltip('设置会话').last);
    await tester.pumpAndSettle();
    expect(find.text('会话设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) await binding.takeScreenshot('silver-widget-settings');
    await tester.tap(find.byTooltip('关闭设置'));
    await tester.pumpAndSettle();
    workspace.cancelEdit();
    await render(Brightness.dark);
    expect(tester.takeException(), isNull);
    if (capture) await binding.takeScreenshot('graphite-sessions');
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
    ]);
    await tester.pumpAndSettle();
    workspace.setActivePage('page-main');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (capture) await binding.takeScreenshot('graphite-landscape');
    final wideBackground = find.byKey(
      const ValueKey('page-edit-background-page-main'),
    );
    await tester.longPressAt(
      tester.getTopLeft(wideBackground) + const Offset(.25, .25),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置会话').last);
    await tester.pumpAndSettle();
    expect(find.text('完成').hitTestable(), findsOneWidget);
    expect(find.text('取消').hitTestable(), findsOneWidget);
    expect(find.byTooltip('关闭设置').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) await binding.takeScreenshot('graphite-landscape-editor');
    workspace.cancelEdit();
    await tester.pumpAndSettle();
    await display.setWorkbenchActive(false);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    await tester.pumpWidget(const SizedBox());
  });
}
