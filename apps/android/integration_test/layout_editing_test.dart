import 'package:deskbar/connection.dart';
import 'package:deskbar/layout_repository.dart';
import 'package:deskbar/layout_workspace.dart';
import 'package:deskbar/rawblock.dart';
import 'package:deskbar/workbench_canvas.dart';
import 'package:deskbar/workbench_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/workbench_fixture.dart';

class _MemoryLayouts extends LayoutRepository {
  @override
  Future<void> save(LayoutDocument document) async {}
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'drag title, displace neighbors and resize edges in both orientations',
    (tester) async {
      final connection = Connection()
        ..phase = ConnectionPhase.online
        ..data = WorkbenchData(snapshot());
      final workspace = LayoutWorkspace(
        document: LayoutDocument(
          activePageId: 'edit',
          pages: [
            LayoutPage(
              id: 'edit',
              name: '编辑',
              widgets: [
                for (final id in ['quota', 'sessions'])
                  LayoutWidget(
                    id: id,
                    type: id == 'quota' ? 'usage' : 'sessions',
                    title: id == 'quota' ? 'Codex 额度' : '近期会话',
                    options: LayoutWorkspace.defaultOptions(
                      id == 'quota' ? 'usage' : 'sessions',
                    ),
                    placements: {
                      LayoutOrientation.portrait: GridPlacement(
                        x: id == 'quota' ? 0 : 8,
                        y: 0,
                        w: 8,
                        h: 48,
                      ),
                      LayoutOrientation.wide: GridPlacement(
                        x: id == 'quota' ? 0 : 24,
                        y: 0,
                        w: 24,
                        h: 48,
                      ),
                    },
                  ),
              ],
            ),
          ],
        ),
      )..beginEdit();
      addTearDown(connection.dispose);
      addTearDown(workspace.dispose);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
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
                  repository: _MemoryLayouts(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await render(Brightness.light);
      const capture = bool.fromEnvironment('DESKBAR_SCREENSHOTS');
      if (capture) await binding.convertFlutterSurfaceToImage();
      Future<void> screenshot(String name) async {
        await tester.pump(const Duration(milliseconds: 300));
        if (capture) await binding.takeScreenshot(name);
      }

      await screenshot('editing-portrait-before');
      final before = workspace.document.toJson();
      final neighbor = find.byKey(const ValueKey('widget-edit-frame-sessions'));
      final width = tester.getSize(neighbor).width + 4;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('widget-move-quota'))),
      );
      await gesture.moveBy(Offset(width, 0));
      await tester.pumpAndSettle();
      expect(workspace.document.toJson(), before);
      await screenshot('editing-portrait-preview');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        workspace
            .findWidget('quota')!
            .placementFor(LayoutOrientation.portrait)
            .x,
        8,
      );
      expect(
        workspace
            .findWidget('sessions')!
            .placementFor(LayoutOrientation.portrait)
            .x,
        0,
      );
      workspace.document.validate();
      workspace.undo();
      await tester.pumpAndSettle();
      expect(workspace.document.toJson(), before);
      await tester.drag(
        find.byKey(const ValueKey('widget-bottom-quota')),
        const Offset(0, -1000),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const ValueKey('widget-edit-frame-quota')))
            .height,
        inInclusiveRange(48, 64),
      );
      await screenshot('editing-portrait-minimum');
      expect(tester.takeException(), isNull);
      workspace.undo();
      await tester.pumpAndSettle();
      final fullCanvas = tester.getRect(find.byType(PageView));
      await tester.tap(find.byKey(const ValueKey('widget-move-sessions')));
      await tester.pumpAndSettle();
      final floating = find.byKey(const ValueKey('floating-editor-window'));
      final titlebar = find.byKey(const ValueKey('floating-editor-titlebar'));
      expect(tester.getRect(find.byType(PageView)), fullCanvas);
      await screenshot('floating-editor-portrait');
      await tester.drag(titlebar, const Offset(-1000, -1000));
      await tester.pumpAndSettle();
      final movedWindow = tester.getRect(floating);
      await tester.drag(
        find.byKey(const PageStorageKey('widget-inspector-sessions')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(floating), movedWindow);
      expect(tester.getRect(find.byType(PageView)), fullCanvas);
      expect(workspace.document.toJson(), before);
      expect(tester.takeException(), isNull);
      await screenshot('floating-editor-portrait-moved');
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
      await render(Brightness.dark);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final frame = find.byKey(const ValueKey('widget-edit-frame-quota'));
      final original = tester.getRect(frame);
      await tester.drag(
        find.byKey(const ValueKey('widget-right-quota')),
        Offset(-original.width / 4, 0),
      );
      await tester.pumpAndSettle();
      expect(
        workspace.findWidget('quota')!.placementFor(LayoutOrientation.wide).w,
        lessThan(24),
      );
      expect(tester.getRect(frame).left, original.left);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(find.text('完成').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot('editing-landscape-edges');
      final wideCanvas = tester.getRect(find.byType(PageView));
      await tester.tap(find.byKey(const ValueKey('widget-move-quota')));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(PageView)), wideCanvas);
      await screenshot('floating-editor-landscape');
      await tester.drag(titlebar, const Offset(-1000, -1000));
      await tester.pumpAndSettle();
      expect(wideCanvas.contains(tester.getRect(floating).topLeft), isTrue);
      expect(wideCanvas.contains(tester.getRect(floating).bottomRight), isTrue);
      expect(tester.takeException(), isNull);
      await screenshot('floating-editor-landscape-moved');
      await tester.pumpWidget(const SizedBox());
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    },
  );
}
