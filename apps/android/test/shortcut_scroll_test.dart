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
  test(
    'shortcut rows and page capacity persist independently and validate',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'deskbar-shortcut-pages-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final workspace = LayoutWorkspace()..beginEdit();
      addTearDown(workspace.dispose);
      expect(shortcutRows({}), 1);
      expect(shortcutRows({'rows': 'auto'}), 1);
      expect(shortcutDisplayLimit({}), 0);
      expect(
        shortcutDisplayLimit(LayoutWorkspace.defaultOptions('shortcuts')),
        0,
      );
      workspace.updateWidget(
        'main-shortcuts',
        options: {'rows': 2, 'maxShortcuts': 5},
      );
      expect(
        shortcutDisplayLimit(workspace.findWidget('apps-shortcuts')!.options),
        0,
      );
      workspace.undo();
      expect(
        shortcutDisplayLimit(workspace.findWidget('main-shortcuts')!.options),
        0,
      );
      workspace.redo();
      await LayoutRepository(directory: directory).save(workspace.document);
      final saved = (await LayoutRepository(
        directory: directory,
      ).load()).document;
      final options = saved.pages.first.widgets
          .firstWhere((w) => w.id == 'main-shortcuts')
          .options;
      expect(shortcutRows(options), 2);
      expect(shortcutDisplayLimit(options), 5);
      for (final invalid in [-1, 65, 1.5, '6', double.infinity]) {
        expect(
          workspace.updateWidget(
            'main-shortcuts',
            options: {'maxShortcuts': invalid},
          ),
          false,
        );
      }
      for (final invalid in [0, 13, 1.5, '2', double.infinity]) {
        expect(
          workspace.updateWidget('main-shortcuts', options: {'rows': invalid}),
          false,
        );
      }
      for (final limit in [0, 1, 64]) {
        expect(
          workspace.updateWidget(
            'main-shortcuts',
            options: {'maxShortcuts': limit},
          ),
          true,
        );
      }
    },
  );

  for (final limit in [0, 1, 5, 64]) {
    testWidgets('rows and page capacity $limit adapt and preserve every entry', (
      tester,
    ) async {
      final connection = shortcuts(12);
      addTearDown(connection.dispose);
      Future<void> mount(
        double width,
        double height, {
        bool labels = false,
        double scale = 1,
      }) => tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          builder: (context, child) => RepaintBoundary(
            key: const ValueKey('shortcut-shot'),
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: height,
                child: WorkbenchWidgetBody(
                  connection: connection,
                  id: 'grid',
                  type: 'shortcuts',
                  binding: const {},
                  options: {
                    'rows': 2,
                    'maxShortcuts': limit,
                    'labels': labels,
                    'alignment': 'center',
                  },
                ),
              ),
            ),
          ),
        ),
      );
      for (final size in [
        const Size(600, 280),
        const Size(220, 180),
        const Size(120, 88),
      ]) {
        await mount(size.width, size.height);
        await tester.pumpAndSettle();
        final dock = find.byKey(const PageStorageKey('shortcuts-grid'));
        final scroll = tester.state<ScrollableState>(
          find.descendant(of: dock, matching: find.byType(Scrollable)),
        );
        scroll.position.jumpTo(0);
        await tester.pumpAndSettle();
        final first = find.byKey(const ValueKey('shortcut-grid-s0'));
        expect(first.hitTestable(), findsOneWidget);
        final capacity = limit == 0 ? 12 : limit.clamp(1, 12);
        final columns = (capacity / capacity.clamp(1, 2)).ceil();
        if (capacity > 1) {
          final nextRow = find.byKey(ValueKey('shortcut-grid-s$columns'));
          expect(
            tester.getTopLeft(nextRow).dy,
            greaterThan(tester.getTopLeft(first).dy),
          );
        }
        if (limit > 0) {
          expect(
            tester.widget<PageView>(dock).childrenDelegate.estimatedChildCount,
            (12 / capacity).ceil(),
          );
          for (var i = 0; i < capacity; i++) {
            final rect = tester.getRect(
              find.byKey(ValueKey('shortcut-grid-s$i')),
            );
            expect(rect.left, greaterThanOrEqualTo(3.99));
            expect(rect.right, lessThanOrEqualTo(size.width - 3.99));
          }
        }
        final last = find.byKey(const ValueKey('shortcut-grid-s11'));
        await tester.dragUntilVisible(
          last.hitTestable(),
          dock,
          const Offset(-160, 0),
          maxIteration: 60,
        );
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOneWidget);
        expect(find.byType(Scrollbar), findsNothing);
        expect(tester.takeException(), isNull);
        if (size.width == 600 && limit == 5) {
          scroll.position.jumpTo(0);
          await tester.pumpAndSettle();
          await capture(tester, 'shortcut-two-rows');
          await tester.drag(dock, const Offset(-400, 0));
          await tester.pumpAndSettle();
          expect((scroll.position as PageMetrics).page, closeTo(1, .001));
          await capture(tester, 'shortcut-second-page');
          // Keep the selected page on refresh and resize, then clamp when data shrinks.
          await mount(420, 360, labels: true, scale: 1.8);
          await tester.pumpAndSettle();
          expect((scroll.position as PageMetrics).page, closeTo(1, .001));
          await capture(tester, 'shortcut-labels-large-text');
          final removed = connection.data!.shortcuts.sublist(2);
          connection.data!.shortcuts.removeRange(2, 12);
          await mount(420, 360, labels: true, scale: 1.8);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('shortcut-grid-s1')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          connection.data!.shortcuts.addAll(removed);
        }
      }
    });
  }

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

  for (final (count, limit) in [(1, 0), (12, 0), (12, 5)]) {
    testWidgets(
      'dock gestures and page gestures cooperate with $count entries, limit $limit',
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
                  options: {
                    ...LayoutWorkspace.defaultOptions('shortcuts'),
                    'maxShortcuts': limit,
                    'rows': limit > 0 ? 2 : 1,
                  },
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
          await gesture.panZoomUpdate(start, pan: const Offset(-560, 0));
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
      final rows = find.descendant(
        of: find.byKey(const ValueKey('shortcut-rows-main-shortcuts')),
        matching: find.byType(TextField),
      );
      await tester.enterText(rows, '2');
      tester.widget<TextField>(rows).onSubmitted!('2');
      await tester.pumpAndSettle();
      final limitSwitch = find.widgetWithText(SwitchListTile, '限制单页数量');
      expect(tester.widget<SwitchListTile>(limitSwitch).value, false);
      tester.widget<SwitchListTile>(limitSwitch).onChanged!(true);
      await tester.pumpAndSettle();
      final limit = find.descendant(
        of: find.byKey(const ValueKey('shortcut-limit-main-shortcuts')),
        matching: find.byType(TextField),
      );
      await tester.enterText(limit, '5');
      tester.widget<TextField>(limit).onSubmitted!('5');
      await tester.pumpAndSettle();
      expect(shortcutRows(workspace.findWidget('main-shortcuts')!.options), 2);
      expect(
        shortcutDisplayLimit(workspace.findWidget('main-shortcuts')!.options),
        5,
      );
      workspace.undo();
      await tester.pumpAndSettle();
      expect(
        shortcutDisplayLimit(workspace.findWidget('main-shortcuts')!.options),
        6,
      );
      workspace.redo();
      await tester.pumpAndSettle();
      await capture(tester, 'shortcut-inspector');
      tester.view.physicalSize = const Size(800, 1000);
      await tester.pumpAndSettle();
      await capture(tester, 'shortcut-inspector-narrow');
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(1400, 1000);
      await tester.pumpAndSettle();
      tester.widget<SwitchListTile>(limitSwitch).onChanged!(false);
      await tester.pumpAndSettle();
      expect(
        shortcutDisplayLimit(workspace.findWidget('main-shortcuts')!.options),
        0,
      );
      expect(limit, findsNothing);
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
