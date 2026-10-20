import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:deskbar/connection.dart';
import 'package:deskbar/layout_repository.dart';
import 'package:deskbar/layout_workspace.dart';
import 'package:deskbar/rawblock.dart';
import 'package:deskbar/workbench_canvas.dart';
import 'package:deskbar/workbench_content.dart';
import 'package:deskbar/workbench_data.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'workbench_fixture.dart';

class _Layouts extends LayoutRepository {
  @override
  Future<void> save(LayoutDocument document) async {}
}

Connection shortcuts(int count) {
  final data = snapshot();
  final original = Map<String, dynamic>.from(
    (data['shortcuts'] as List).single as Map,
  );
  data['shortcuts'] = [
    for (var i = 0; i < count; i++)
      {...original, 'shortcut_id': 's$i', 'name': '入口 $i'},
  ];
  return Connection()
    ..data = WorkbenchData(data)
    ..phase = ConnectionPhase.online;
}

Future<void> capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['DESKBAR_SCREENSHOT_DIR'];
  if (directory == null) return;
  await (FontLoader(
    'Noto Sans SC',
  )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('shortcut-shot')),
    );
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets('width clips icons without shrinking, wrapping or a scrollbar', (
    tester,
  ) async {
    final connection = shortcuts(6);
    addTearDown(connection.dispose);
    Future<void> mount(double width, double gap) => tester.pumpWidget(
      MaterialApp(
        theme: rawBlockTheme(),
        builder: (context, child) => RepaintBoundary(
          key: const ValueKey('shortcut-shot'),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 88,
              child: WorkbenchWidgetBody(
                connection: connection,
                id: 'dock',
                type: 'shortcuts',
                binding: const {},
                options: {'alignment': 'center', 'spacing': gap},
              ),
            ),
          ),
        ),
      ),
    );
    Rect tile(int i) =>
        tester.getRect(find.byKey(ValueKey('shortcut-dock-s$i')));
    await mount(700, 0);
    final width = tile(0).width;
    expect(tile(1).left - tile(0).right, closeTo(0, .01));
    expect((tile(0).left + tile(5).right) / 2, closeTo(350, .01));
    await mount(700, 16);
    expect(tile(1).left - tile(0).right, closeTo(16, .01));
    for (final viewportWidth in [220.0, 36.0]) {
      await mount(viewportWidth, 16);
      await tester.pumpAndSettle();
      expect(tile(0).width, width);
      expect(tile(0).top, tile(5).top);
      expect(find.byType(Scrollbar), findsNothing);
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(tile(5).right, closeTo(viewportWidth - 4, .01));
      if (viewportWidth == 220) await capture(tester, 'shortcut-narrow');
      expect(tester.takeException(), isNull);
    }
  });

  for (final count in [1, 12]) {
    testWidgets(
      'dock gestures and page gestures cooperate with $count entries',
      (tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final connection = shortcuts(count);
        addTearDown(connection.dispose);
        var commands = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('app.deskbar/connection'),
              (call) async {
                if (call.method == 'command') commands++;
                return null;
              },
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('app.deskbar/connection'),
                null,
              ),
        );
        final document = LayoutDocument(
          activePageId: 'one',
          pages: [
            LayoutPage(
              id: 'one',
              name: '一',
              widgets: [
                LayoutWidget(
                  id: 'dock',
                  type: 'shortcuts',
                  binding: const {},
                  options: LayoutWorkspace.defaultOptions('shortcuts'),
                  placements: {
                    LayoutOrientation.wide: GridPlacement(
                      x: 0,
                      y: 0,
                      w: 48,
                      h: 48,
                    ),
                    LayoutOrientation.portrait: GridPlacement(
                      x: 0,
                      y: 0,
                      w: 8,
                      h: 12,
                    ),
                  },
                ),
              ],
            ),
            LayoutPage(id: 'two', name: '二', widgets: []),
          ],
        );
        final data = snapshot();
        final original = Map<String, dynamic>.from(
          (data['shortcuts'] as List).single as Map,
        );
        data['shortcuts'] = [
          for (var i = 0; i < count; i++)
            {...original, 'shortcut_id': 's$i', 'name': '入口 $i'},
        ];
        data['layout'] = document.toJson();
        connection.data = WorkbenchData(data);
        final workspace = LayoutWorkspace(document: document);
        addTearDown(workspace.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: rawBlockTheme(),
            builder: (context, child) => RepaintBoundary(
              key: const ValueKey('shortcut-shot'),
              child: child!,
            ),
            home: Scaffold(
              body: WorkbenchCanvas(
                connection: connection,
                workspace: workspace,
                repository: _Layouts(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final dock = find.byKey(const PageStorageKey('shortcuts-dock'));
        final scroll = tester.state<ScrollableState>(
          find.descendant(of: dock, matching: find.byType(Scrollable)),
        );
        final start = tester.getCenter(dock);
        if (count > 1) {
          // Overscroll at the left edge must not hand the same drag to PageView.
          await tester.dragFrom(start, const Offset(500, 0));
          await tester.pumpAndSettle();
          expect(workspace.activePage.id, 'one');
          await tester.dragFrom(start, const Offset(-500, 0));
          await tester.pumpAndSettle();
          expect(scroll.position.pixels, greaterThan(0));
          expect(workspace.activePage.id, 'one');
          scroll.position.jumpTo(scroll.position.maxScrollExtent);
          await tester.pump();
          await tester.dragFrom(start, const Offset(-500, 0));
          await tester.pumpAndSettle();
          expect(workspace.activePage.id, 'one');
          for (final offset in [100.0, -100.0]) {
            scroll.position.jumpTo(
              offset > 0 ? scroll.position.maxScrollExtent : 0,
            );
            await tester.pump();
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: start,
                scrollDelta: Offset(offset, 0),
              ),
            );
            await tester.pumpAndSettle();
            expect(workspace.activePage.id, 'one');
          }
          // Real pan/zoom trackpads use the same inner horizontal scroll owner.
          final gesture = await tester.createGesture(
            kind: PointerDeviceKind.trackpad,
          );
          await gesture.panZoomStart(start);
          await gesture.panZoomUpdate(start, pan: const Offset(-40, 0));
          await gesture.panZoomUpdate(start, pan: const Offset(-160, 0));
          await gesture.panZoomEnd();
          await tester.pumpAndSettle();
          expect(workspace.activePage.id, 'one');
          expect(scroll.position.pixels, greaterThan(0));
          await tester.dragFrom(const Offset(600, 40), const Offset(-600, 0));
        } else {
          expect(scroll.position.maxScrollExtent, 0);
          await tester.dragFrom(start, const Offset(-600, 0));
        }
        await tester.pumpAndSettle();
        expect(workspace.activePage.id, 'two');
        expect(commands, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'center spacing slider persists, undoes and hides for other alignment',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connection = shortcuts(6);
      final workspace = LayoutWorkspace();
      addTearDown(connection.dispose);
      addTearDown(workspace.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          builder: (context, child) => RepaintBoundary(
            key: const ValueKey('shortcut-shot'),
            child: child!,
          ),
          home: Scaffold(
            body: WorkbenchCanvas(
              connection: connection,
              workspace: workspace,
              repository: _Layouts(),
              allowEditing: true,
              previewSize: const Size(1280, 720),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('outline-main-shortcuts')));
      await tester.pumpAndSettle();
      workspace.updateWidget(
        'main-shortcuts',
        options: {'alignment': 'center'},
      );
      await tester.pumpAndSettle();
      final slider = find.byKey(
        const ValueKey('shortcut-spacing-main-shortcuts'),
      );
      expect(tester.widget<Slider>(slider).min, 0);
      expect(tester.widget<Slider>(slider).max, 16);
      for (final spacing in [0.0, 16.0]) {
        tester.widget<Slider>(slider).onChanged!(spacing);
        await tester.pumpAndSettle();
        expect(
          workspace.findWidget('main-shortcuts')!.options['spacing'],
          spacing,
        );
      }
      workspace.undo();
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, 0);
      workspace.redo();
      await tester.pumpAndSettle();
      final saved = LayoutDocument.fromJson(workspace.document.toJson());
      expect(
        saved.pages.first.widgets
            .firstWhere((w) => w.id == 'main-shortcuts')
            .options['spacing'],
        16,
      );
      await capture(tester, 'shortcut-inspector');
      for (final alignment in ['left', 'right', 'spaceEvenly']) {
        workspace.updateWidget(
          'main-shortcuts',
          options: {'alignment': alignment},
        );
        await tester.pumpAndSettle();
        expect(slider, findsNothing);
      }
      for (final invalid in [-1, 17, '8', double.infinity]) {
        expect(
          workspace.updateWidget(
            'main-shortcuts',
            options: {'spacing': invalid},
          ),
          false,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}
