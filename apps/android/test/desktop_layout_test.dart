import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deskbar/connection.dart';
import 'package:deskbar/layout_repository.dart';
import 'package:deskbar/layout_workspace.dart';
import 'package:deskbar/rawblock.dart';
import 'package:deskbar/workbench_canvas.dart';
import 'package:deskbar/workbench_content.dart';
import 'package:deskbar/workbench_data.dart';
import 'workbench_fixture.dart' as fixture;

class UnusedRepository extends LayoutRepository {
  @override
  Future<LayoutLoadResult> load() =>
      throw StateError('Mobile must not load local layouts');
  @override
  Future<void> save(LayoutDocument document) =>
      throw StateError('Mobile must not save layouts');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> layout() =>
      jsonDecode(File('../../protocol/layout.example.json').readAsStringSync())
          as Map<String, dynamic>;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.deskbar/layout'),
          (_) async => null,
        );
  });
  for (final size in [const Size(400, 800), const Size(1280, 720)]) {
    testWidgets('direct selection docks inspector outside $size', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connection = Connection()..data = WorkbenchData(fixture.snapshot());
      final workspace = LayoutWorkspace();
      addTearDown(connection.dispose);
      addTearDown(workspace.dispose);
      Widget editor(Size preview) => MaterialApp(
        theme: rawBlockTheme(),
        home: Scaffold(
          body: WorkbenchCanvas(
            connection: connection,
            workspace: workspace,
            allowEditing: true,
            previewSize: preview,
            previewTextScale: 1.8,
          ),
        ),
      );
      await tester.pumpWidget(editor(size));
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byType(PageView));
      final body = find.byKey(const ValueKey('widget-move-main-sessions'));
      final before = tester.getSize(body);
      expect(find.text('编辑页面与组件'), findsNothing);
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      expect(workspace.editing, isFalse);
      await tester.tap(body);
      await tester.pumpAndSettle();
      expect(workspace.selectedWidgetId, 'main-sessions');
      expect(workspace.editing, isTrue);
      expect(
        find.byKey(const ValueKey('title-main-sessions')).hitTestable(),
        findsOneWidget,
      );
      final inspector = tester.getRect(
        find.byKey(const ValueKey('editor-inspector')),
      );
      expect(canvas.overlaps(inspector), isFalse);
      if (size.width > size.height) {
        expect(inspector.top, greaterThanOrEqualTo(canvas.bottom));
      } else {
        expect(inspector.left, greaterThanOrEqualTo(canvas.right));
      }
      expect(tester.getRect(find.byType(PageView)), canvas);
      expect(tester.getSize(body), before);
      final name = find.byKey(const ValueKey('title-main-sessions'));
      await tester.enterText(name, '正在编辑');
      await tester.pumpAndSettle();
      await tester.pumpWidget(editor(Size(size.height, size.width)));
      await tester.pumpAndSettle();
      expect(workspace.selectedWidgetId, 'main-sessions');
      expect(workspace.findWidget('main-sessions')!.title, '正在编辑');
      final rotatedCanvas = tester.getRect(find.byType(PageView));
      final rotatedInspector = tester.getRect(
        find.byKey(const ValueKey('editor-inspector')),
      );
      expect(rotatedCanvas.overlaps(rotatedInspector), isFalse);
      if (size.width > size.height) {
        expect(
          rotatedInspector.left,
          greaterThanOrEqualTo(rotatedCanvas.right),
        );
      } else {
        expect(
          rotatedInspector.top,
          greaterThanOrEqualTo(rotatedCanvas.bottom),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'dragging component content keeps both orientation layouts independent',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = LayoutWorkspace(
        document: LayoutDocument(
          activePageId: 'main',
          pages: [
            LayoutPage(
              id: 'main',
              name: '测试',
              widgets: [
                LayoutWidget(
                  id: 'movable',
                  type: 'usage',
                  placements: {
                    LayoutOrientation.wide: const GridPlacement(
                      x: 4,
                      y: 4,
                      w: 16,
                      h: 16,
                    ),
                    LayoutOrientation.portrait: const GridPlacement(
                      x: 2,
                      y: 8,
                      w: 8,
                      h: 32,
                    ),
                  },
                ),
              ],
            ),
          ],
        ),
      );
      final connection = Connection()..data = WorkbenchData(fixture.snapshot());
      addTearDown(workspace.dispose);
      addTearDown(connection.dispose);
      for (final size in [const Size(400, 800), const Size(1280, 720)]) {
        final orientation = size.width > size.height
            ? LayoutOrientation.wide
            : LayoutOrientation.portrait;
        final other = orientation == LayoutOrientation.wide
            ? LayoutOrientation.portrait
            : LayoutOrientation.wide;
        await tester.pumpWidget(
          MaterialApp(
            theme: rawBlockTheme(),
            home: Scaffold(
              body: WorkbenchCanvas(
                connection: connection,
                workspace: workspace,
                allowEditing: true,
                previewSize: size,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final body = find.byKey(const ValueKey('widget-move-movable'));
        await tester.tap(body);
        await tester.pumpAndSettle();
        final original = workspace.document.toJson();
        final originalOther = workspace
            .findWidget('movable')!
            .placementFor(other);
        final before = workspace
            .findWidget('movable')!
            .placementFor(orientation);
        final rect = tester.getRect(body);
        // Begin well below the old title strip, in the actual component content.
        await tester.dragFrom(
          Offset(rect.center.dx, rect.top + rect.height * .7),
          const Offset(60, 40),
        );
        await tester.pumpAndSettle();
        final after = workspace
            .findWidget('movable')!
            .placementFor(orientation);
        expect(after.x, greaterThan(before.x));
        expect(after.y, greaterThan(before.y));
        expect(
          workspace.findWidget('movable')!.placementFor(other),
          originalOther,
        );
        workspace.undo();
        await tester.pumpAndSettle();
        expect(workspace.document.toJson(), original);
        expect(workspace.canUndo, isFalse);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'mobile receives computer layouts, reports geometry and cannot edit',
    (tester) async {
      final reports = <dynamic>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('app.deskbar/connection'),
            (call) async {
              if (call.method == 'display') reports.add(call.arguments);
              return null;
            },
          );
      final initial = layout();
      final connection = Connection()
        ..phase = ConnectionPhase.online
        ..data = WorkbenchData({
          ...fixture.snapshot(),
          'layout': initial,
          'layout_revision': 1,
        });
      final workspace = LayoutWorkspace();
      var settings = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: WorkbenchCanvas(
              connection: connection,
              workspace: workspace,
              repository: UnusedRepository(),
              onConnectionSettings: () => settings++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(workspace.activePage.id, 'main');
      expect(workspace.editing, isFalse);
      expect(find.text('编辑页面与组件'), findsNothing);
      await tester.longPressAt(
        tester.getTopLeft(find.byType(PageView)) + const Offset(2, 2),
      );
      await tester.pumpAndSettle();
      expect(settings, 1);
      expect(workspace.editing, isFalse);
      expect(reports.last['layout_revision'], 1);
      expect(
        reports.last['width'],
        tester.getSize(find.byType(PageView)).width,
      );
      final next = layout();
      (next['pages'] as List).first['widgets'] = [];
      connection.data = WorkbenchData({
        ...fixture.snapshot(),
        'layout': next,
        'layout_revision': 2,
      });
      connection.notifyListeners();
      await tester.pumpAndSettle();
      expect(workspace.activePage.widgets, isEmpty);
      expect(reports.last['layout_revision'], 2);
      connection.phase = ConnectionPhase.offline;
      connection.notifyListeners();
      await tester.pumpAndSettle();
      expect(workspace.activePage.widgets, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      connection.dispose();
      workspace.dispose();
    },
  );

  testWidgets(
    'desktop edit overlays and debug labels preserve device content dimensions',
    (tester) async {
      final connection = Connection()
        ..phase = ConnectionPhase.online
        ..data = WorkbenchData(fixture.snapshot());
      final workspace = LayoutWorkspace(
        document: LayoutDocument.fromJson(layout()),
      );
      Widget screen(bool debug) => MaterialApp(
        theme: rawBlockTheme(),
        home: Scaffold(
          body: WorkbenchCanvas(
            allowEditing: true,
            connection: connection,
            workspace: workspace,
            previewSize: const Size(1280, 720),
            debugLayout: debug,
          ),
        ),
      );
      await tester.pumpWidget(screen(false));
      await tester.pumpAndSettle();
      final before = tester.getSize(find.byType(WorkbenchWidgetBody));
      workspace.beginEdit();
      await tester.pumpWidget(screen(true));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(WorkbenchWidgetBody)), before);
      expect(find.textContaining('区域 1274.0 × 714.0 dp'), findsOneWidget);
      expect(find.textContaining('4 列 · 卡片 307.5 × 107.7 dp'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      connection.dispose();
      workspace.dispose();
    },
  );
}
