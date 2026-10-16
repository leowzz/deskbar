import 'dart:async';
import 'package:deskbar/connection.dart';
import 'package:deskbar/display_preferences.dart';
import 'package:deskbar/layout_repository.dart';
import 'package:deskbar/layout_workspace.dart';
import 'package:deskbar/rawblock.dart';
import 'package:deskbar/workbench_canvas.dart';
import 'package:deskbar/workbench_content.dart';
import 'package:deskbar/workbench_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'workbench_fixture.dart';

class MemoryLayouts extends LayoutRepository {
  LayoutDocument? saved;
  Completer<void>? pending;
  bool fail = false;
  @override
  Future<void> save(LayoutDocument document) async {
    if (pending != null) await pending!.future;
    if (fail) throw StateError('save');
    saved = document;
  }
}

Future<void> launch(
  WidgetTester tester,
  LayoutWorkspace workspace, {
  Size size = const Size(1000, 760),
  bool editor = true,
  Size preview = const Size(360, 640),
  double scale = 1,
  Brightness brightness = Brightness.light,
  MemoryLayouts? repository,
  bool withChrome = false,
  Connection? liveConnection,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final connection =
      liveConnection ??
      (Connection()
        ..phase = ConnectionPhase.online
        ..hostName = '工作电脑'
        ..data = WorkbenchData({
          ...snapshot(),
          'layout': workspace.document.toJson(),
        }));
  if (liveConnection == null) addTearDown(connection.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: rawBlockTheme(brightness),
      home: Scaffold(
        appBar: withChrome ? AppBar(title: const Text('DeskBar 工作台')) : null,
        body: SafeArea(
          child: Column(
            children: [
              if (withChrome && size.height > size.width)
                const SizedBox(height: 54),
              Expanded(
                child: WorkbenchCanvas(
                  allowEditing: editor,
                  previewSize: editor ? preview : null,
                  connection: connection,
                  workspace: workspace,
                  repository: repository ?? MemoryLayouts(),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

LayoutWorkspace editableWorkspace({bool pair = false}) => LayoutWorkspace(
  document: LayoutDocument(
    activePageId: 'edit-page',
    pages: [
      LayoutPage(
        id: 'edit-page',
        name: '编辑',
        widgets: [
          for (final id in pair ? ['a', 'b'] : ['a'])
            LayoutWidget(
              id: id,
              type: 'usage',
              title: '用量 $id',
              placements: {
                for (final orientation in LayoutOrientation.values)
                  orientation: GridPlacement(
                    x: pair ? (id == 'a' ? 0 : 8) : 4,
                    y: pair ? 0 : 8,
                    w: 8,
                    h: 32,
                  ),
              },
            ),
        ],
      ),
    ],
  ),
)..beginEdit();

void main() {
  testWidgets(
    'whole component drag previews displacement, commits once and undo restores both',
    (tester) async {
      final workspace = editableWorkspace(pair: true);
      addTearDown(workspace.dispose);
      await launch(tester, workspace);
      final before = workspace.document.toJson();
      final b = find.byKey(const ValueKey('widget-edit-frame-b'));
      final originalB = tester.getRect(b);
      final move = find.byKey(const ValueKey('widget-move-a'));
      final gesture = await tester.startGesture(tester.getCenter(move));
      await gesture.moveBy(Offset(originalB.width + 2, 0));
      await tester.pumpAndSettle();
      expect(workspace.document.toJson(), before);
      expect(workspace.canUndo, false);
      expect(tester.getRect(b).left, lessThan(originalB.left));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        workspace.findWidget('a')!.placementFor(LayoutOrientation.portrait).x,
        8,
      );
      expect(
        workspace.findWidget('b')!.placementFor(LayoutOrientation.portrait).x,
        0,
      );
      workspace.document.validate();
      workspace.undo();
      await tester.pumpAndSettle();
      expect(workspace.document.toJson(), before);
      expect(workspace.canUndo, false);
      expect(tester.getRect(b), originalB);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelled drag clears preview without a draft or history change',
    (tester) async {
      final workspace = editableWorkspace(pair: true);
      addTearDown(workspace.dispose);
      await launch(tester, workspace);
      final before = workspace.document.toJson();
      final b = find.byKey(const ValueKey('widget-edit-frame-b'));
      final originalB = tester.getRect(b);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('widget-move-a'))),
      );
      await gesture.moveBy(Offset(originalB.width + 2, 0));
      await tester.pumpAndSettle();
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(workspace.document.toJson(), before);
      expect(workspace.canUndo, false);
      expect(tester.getRect(b), originalB);
      expect(tester.takeException(), isNull);
    },
  );

  for (final edge in ['left', 'right', 'bottom', 'bottomLeft', 'bottomRight']) {
    testWidgets(
      '$edge edge resizes with fine steps and a button-height minimum',
      (tester) async {
        final workspace = editableWorkspace();
        addTearDown(workspace.dispose);
        await launch(tester, workspace);
        await tester.tap(find.byKey(const ValueKey('widget-move-a')));
        await tester.pumpAndSettle();
        final before = workspace
            .findWidget('a')!
            .placementFor(LayoutOrientation.portrait);
        final frame = find.byKey(const ValueKey('widget-edit-frame-a'));
        final rect = tester.getRect(frame);
        final horizontal = edge == 'left' || edge == 'bottomLeft'
            ? 22.0
            : -22.0;
        await tester.drag(
          find.byKey(ValueKey('widget-$edge-a')),
          Offset(
            edge == 'bottom' ? 0 : horizontal,
            edge == 'left' || edge == 'right' ? 0 : -1000,
          ),
        );
        await tester.pumpAndSettle();
        final after = workspace
            .findWidget('a')!
            .placementFor(LayoutOrientation.portrait);
        if (edge != 'bottom') {
          expect(after.w, before.w - 1);
          if (edge == 'left' || edge == 'bottomLeft') {
            expect(after.x + after.w, before.x + before.w);
          } else {
            expect(after.x, before.x);
          }
        }
        if (edge != 'left' && edge != 'right') {
          expect(tester.getSize(frame).height, inInclusiveRange(48, 60));
          expect(after.y, before.y);
        }
        workspace.document.validate();
        workspace.undo();
        await tester.pumpAndSettle();
        expect(tester.getRect(frame), rect);
        expect(workspace.canUndo, false);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in [
    const Size(1000, 760),
    const Size(800, 600),
    const Size(560, 680),
  ]) {
    for (final scale in [1.0, 1.8]) {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        testWidgets('canvas fits $size scale $scale $brightness and settings', (
          tester,
        ) async {
          final workspace = LayoutWorkspace();
          addTearDown(workspace.dispose);
          await launch(
            tester,
            workspace,
            size: size,
            scale: scale,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          workspace.beginEdit();
          await tester.pumpAndSettle();
          expect(workspace.editing, isTrue);
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('设置会话').first);
          await tester.pumpAndSettle();
          expect(find.widgetWithText(TextField, '卡片目标宽度'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
  testWidgets(
    'number controls step, repeat while held and disable at minimums',
    (tester) async {
      final workspace = LayoutWorkspace();
      addTearDown(workspace.dispose);
      await launch(tester, workspace);
      workspace.beginEdit();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置会话').first);
      await tester.pumpAndSettle();

      final density = find.byKey(
        const ValueKey('density-main-sessions-compact'),
      );
      await tester.ensureVisible(density);
      await tester.pumpAndSettle();
      await tester.tap(density);
      await tester.pumpAndSettle();
      await tester.tap(find.text('标准').last);
      await tester.pumpAndSettle();
      expect(
        workspace.findWidget('main-sessions')!.options['itemHeight'],
        96.0,
      );

      final width = find.widgetWithText(TextField, '卡片目标宽度');
      final height = find.widgetWithText(TextField, '卡片目标高度');
      final widthMinus = find.byKey(const ValueKey('number-decrement-卡片目标宽度'));
      final widthPlus = find.byKey(const ValueKey('number-increment-卡片目标宽度'));
      final heightMinus = find.byKey(const ValueKey('number-decrement-卡片目标高度'));
      expect(tester.widget<IconButton>(widthMinus).onPressed, isNotNull);
      expect(
        (tester.widget<IconButton>(widthPlus).icon as Icon).icon,
        Icons.keyboard_arrow_up,
      );
      expect(
        (tester.widget<IconButton>(widthMinus).icon as Icon).icon,
        Icons.keyboard_arrow_down,
      );
      expect(
        tester.getCenter(widthPlus).dy,
        lessThan(tester.getCenter(widthMinus).dy),
      );
      await tester.tap(widthMinus);
      await tester.pumpAndSettle();
      expect(
        workspace.findWidget('main-sessions')!.options['itemWidth'],
        279.0,
      );
      await tester.tap(widthPlus);
      await tester.pumpAndSettle();
      expect(
        workspace.findWidget('main-sessions')!.options['itemWidth'],
        280.0,
      );

      final beforeRepeat =
          workspace.findWidget('main-sessions')!.options['itemWidth'] as double;
      final heldPlus = await tester.startGesture(tester.getCenter(widthPlus));
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 240));
      await heldPlus.up();
      await tester.pumpAndSettle();
      expect(
        workspace.findWidget('main-sessions')!.options['itemWidth'],
        greaterThan(beforeRepeat + 1),
      );

      await tester.enterText(width, '120');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(
        workspace.findWidget('main-sessions')!.options['itemWidth'],
        120.0,
      );
      expect(tester.widget<IconButton>(widthMinus).onPressed, isNull);
      expect(tester.widget<IconButton>(widthMinus).tooltip, '已是最小值');

      await tester.enterText(height, '88');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(
        workspace.findWidget('main-sessions')!.options['itemHeight'],
        96.0,
      );
      expect(tester.widget<IconButton>(heightMinus).onPressed, isNull);
      expect(tester.widget<IconButton>(heightMinus).tooltip, '已是最小值');
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [const Size(360, 640), const Size(800, 360)]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
        'default overview paints usable content at $size $brightness',
        (tester) async {
          final workspace = LayoutWorkspace();
          addTearDown(workspace.dispose);
          await launch(
            tester,
            workspace,
            size: size,
            brightness: brightness,
            withChrome: true,
            editor: false,
          );
          final session = find.text('一个比较长的真实工作任务标题，需要在大字号和窄屏下保持可读');
          final shortcut = find.text('常用应用入口名称很长也能换行');
          expect(session, findsOneWidget);
          expect(shortcut, findsOneWidget);
          expect(session.hitTestable(), findsOneWidget);
          expect(shortcut.hitTestable(), findsOneWidget);
          final card = find.byKey(
            const ValueKey('session-card-main-sessions-session'),
          );
          final grid = find.byKey(
            const PageStorageKey('sessions-main-sessions'),
          );
          expect(
            tester.getRect(card).bottom,
            lessThanOrEqualTo(tester.getRect(grid).bottom + .01),
          );
          final project = find.descendant(
            of: card,
            matching: find.text('DeskBar'),
          );
          expect(project.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(project).bottom,
            lessThanOrEqualTo(tester.getRect(grid).bottom + .01),
          );
          expect(find.textContaining('扩大组件'), findsNothing);
          expect(find.textContaining('图标放不下'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'session rows stay consistent with the device layout at larger text scale',
    (tester) async {
      const size = Size(866.285714, 411.428571);
      final base = LayoutDocument.initial();
      final page = base.activePage;
      final sessions = page.widgets
          .firstWhere((widget) => widget.id == 'main-sessions')
          .copyWith(
            options: const {
              'density': 'normal',
              'fitRows': false,
              'gap': 0,
              'itemHeight': 96.0,
              'itemWidth': 200.0,
              'maxSessions': 20,
              'showTitle': true,
            },
            placements: const {
              LayoutOrientation.wide: GridPlacement(x: 0, y: 0, w: 32, h: 38),
              LayoutOrientation.portrait: GridPlacement(
                x: 0,
                y: 20,
                w: 16,
                h: 52,
              ),
            },
          );
      final usage = page.widgets
          .firstWhere((widget) => widget.id == 'main-usage')
          .copyWith(
            placements: const {
              LayoutOrientation.wide: GridPlacement(x: 32, y: 1, w: 16, h: 13),
              LayoutOrientation.portrait: GridPlacement(
                x: 0,
                y: 0,
                w: 16,
                h: 20,
              ),
            },
          );
      final shortcuts = page.widgets
          .firstWhere((widget) => widget.id == 'main-shortcuts')
          .copyWith(
            options: const {
              'alignment': 'center',
              'columns': 'auto',
              'gapX': 16,
              'gapY': 16,
              'iconSize': 'max',
              'labels': false,
              'rows': 'auto',
              'showTitle': false,
            },
            placements: const {
              LayoutOrientation.wide: GridPlacement(x: 0, y: 38, w: 48, h: 10),
              LayoutOrientation.portrait: GridPlacement(
                x: 0,
                y: 72,
                w: 16,
                h: 24,
              ),
            },
          );
      final document = base.copyWith(
        pages: [
          page.copyWith(widgets: [sessions, usage, shortcuts]),
        ],
      );
      final value = snapshot();
      final original = Map<String, dynamic>.from(
        (value['sessions'] as List).single as Map,
      );
      value['sessions'] = [
        for (var i = 0; i < 6; i++)
          {...original, 'session_id': 'session-$i', 'title': '会话 $i'},
      ];
      value['session_total'] = 6;
      final connection = Connection()
        ..phase = ConnectionPhase.online
        ..data = WorkbenchData({...value, 'layout': document.toJson()});
      addTearDown(connection.dispose);
      final workspace = LayoutWorkspace(document: document);
      addTearDown(workspace.dispose);
      await launch(
        tester,
        workspace,
        size: size,
        scale: 1.5,
        editor: false,
        liveConnection: connection,
      );

      final grid = find.byKey(const PageStorageKey('sessions-main-sessions'));
      expect(find.text('会话 4'), findsOneWidget);
      expect(find.text('会话 5'), findsOneWidget);
      expect(
        tester.getRect(find.text('会话 5')).bottom,
        lessThanOrEqualTo(tester.getRect(grid).bottom + .01),
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final online in [true, false]) {
    testWidgets(
      'compact 136dp body paints one complete card including project online=$online',
      (tester) async {
        final connection = Connection()
          ..phase = online ? ConnectionPhase.online : ConnectionPhase.offline
          ..data = WorkbenchData(snapshot());
        addTearDown(connection.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: rawBlockTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 500,
                  height: 136,
                  child: WorkbenchWidgetBody(
                    connection: connection,
                    id: 'compact',
                    type: 'sessions',
                    options: const {
                      'density': 'compact',
                      'itemHeight': 96,
                      'fitRows': true,
                    },
                    binding: const {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('session-card-compact-session'));
        final grid = find.byKey(const PageStorageKey('sessions-compact'));
        expect(card, findsOneWidget);
        expect(
          tester.getRect(card).bottom,
          lessThanOrEqualTo(tester.getRect(grid).bottom + .01),
        );
        final project = find.descendant(
          of: card,
          matching: find.text('DeskBar'),
        );
        expect(project.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(project).bottom,
          lessThanOrEqualTo(tester.getRect(grid).bottom + .01),
        );
        if (!online) {
          expect(
            find.textContaining('电脑离线', findRichText: true),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'too-short compact body keeps source error and offers expansion',
    (tester) async {
      final value = snapshot();
      (value['sources'] as List).first['health'] = 'failed';
      (value['sources'] as List).first['message'] = '电脑未能读取会话，等待恢复';
      final connection = Connection()
        ..phase = ConnectionPhase.online
        ..data = WorkbenchData(value);
      addTearDown(connection.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 100,
              child: WorkbenchWidgetBody(
                connection: connection,
                id: 'small',
                type: 'sessions',
                options: const {'density': 'compact', 'fitRows': true},
                binding: const {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('电脑未能读取会话'), findsOneWidget);
      expect(find.textContaining('请在电脑端调整组件大小'), findsOneWidget);
      expect(find.byType(GridView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('mobile canvas long press stays read only', (tester) async {
    final workspace = LayoutWorkspace();
    addTearDown(workspace.dispose);
    await launch(tester, workspace, editor: false, size: const Size(360, 640));
    expect(find.byKey(const ValueKey('editor-inspector')), findsNothing);
    final background = find.byKey(
      const ValueKey('page-edit-background-page-main'),
    );
    await tester.longPressAt(
      tester.getTopLeft(background) + const Offset(.25, .25),
    );
    await tester.pumpAndSettle();
    expect(workspace.editing, isFalse);
    expect(
      find.byKey(const ValueKey('widget-edit-frame-main-sessions')),
      findsNothing,
    );
  });
  testWidgets(
    'nonimmersive normal canvas has no page, editing or bottom controls',
    (tester) async {
      final workspace = LayoutWorkspace();
      final connection = Connection()
        ..data = WorkbenchData(snapshot())
        ..phase = ConnectionPhase.online;
      final display = DisplayPreferences(initialImmersive: false);
      addTearDown(workspace.dispose);
      addTearDown(connection.dispose);
      addTearDown(display.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: WorkbenchCanvas(
              allowEditing: false,
              connection: connection,
              workspace: workspace,
              repository: MemoryLayouts(),
              displayPreferences: display,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('总览'), findsNothing);
      expect(find.text('任务'), findsNothing);
      expect(find.text('应用'), findsNothing);
      expect(find.text('1'), findsNothing);
      expect(find.byTooltip('编辑布局'), findsNothing);
      expect(find.byIcon(Icons.fullscreen), findsNothing);
      expect(find.text('近期会话'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'switching inline inspectors isolates instance fields and scrolling',
    (tester) async {
      final value = snapshot();
      final now = value['server_time'] as int;
      final session = Map<String, dynamic>.from(
        (value['sessions'] as List).first as Map,
      );
      value['sessions'] = <dynamic>[
        ...(value['sessions'] as List),
        {...session, 'session_id': 'session-b', 'title': '另一个会话'},
      ];
      (value['sources'] as List).add({
        'source_id': 'sub2api.usage',
        'health': 'ready',
        'message': '',
        'observed_at': now,
        'fresh_until': now + 600,
      });
      value['api_usage'] = [
        {
          'id': 'api-account',
          'label': 'API 账户',
          'actual_cost_micros': 12340000,
          'currency': 'USD',
          'token_count': 1200000,
          'tpm': 4500,
          'window_start': now - 1000,
          'window_end': now + 600,
        },
      ];
      final data = WorkbenchData(value);
      final specs = [
        (
          'session-a',
          'sessions',
          'codex.sessions',
          'session',
          {'density': 'compact', 'itemWidth': 240.0},
        ),
        ('quota', 'usage', 'codex.quota', 'weekly', {'content': 'quota'}),
        (
          'shortcut',
          'shortcuts',
          'host.shortcuts',
          'shortcut',
          {'iconSize': 48.0, 'labels': true},
        ),
        (
          'session-b',
          'sessions',
          'codex.sessions',
          'session-b',
          {'density': 'normal', 'itemWidth': 400.0},
        ),
        ('api', 'usage', 'sub2api.usage', 'api-account', {'content': 'api'}),
      ];
      final widgets = <LayoutWidget>[];
      for (var i = 0; i < specs.length; i++) {
        final spec = specs[i];
        widgets.add(
          LayoutWidget(
            id: spec.$1,
            type: spec.$2,
            title: spec.$1,
            binding: {
              'hostId': 'host',
              'source': spec.$3,
              'resourceId': spec.$4,
            },
            options: {...LayoutWorkspace.defaultOptions(spec.$2), ...spec.$5},
            placements: {
              LayoutOrientation.wide: GridPlacement(
                x: (i % 3) * 4,
                y: (i ~/ 3) * 6,
                w: 4,
                h: 6,
              ).scaled(4),
              LayoutOrientation.portrait: GridPlacement(
                x: 0,
                y: i * 4,
                w: 4,
                h: 4,
              ).scaled(4),
            },
          ),
        );
      }
      final workspace = LayoutWorkspace(
        document: LayoutDocument(
          activePageId: 'instances',
          pages: [LayoutPage(id: 'instances', name: '实例', widgets: widgets)],
        ),
      )..beginEdit();
      addTearDown(workspace.dispose);
      final connection = Connection()
        ..data = data
        ..phase = ConnectionPhase.online;
      addTearDown(connection.dispose);
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: WorkbenchCanvas(
              allowEditing: true,
              connection: connection,
              workspace: workspace,
              repository: MemoryLayouts(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder field(String label) => find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.decoration.labelText == label,
      );
      String? selected(String label) =>
          tester.state<FormFieldState<String>>(field(label)).value;
      Future<void> open(String id) async {
        await tester.tap(find.byKey(ValueKey('widget-move-$id')));
        await tester.pumpAndSettle();
      }

      ScrollableState inspectorScroll() => tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(SingleChildScrollView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await open('session-a');
      final name = find.byKey(const ValueKey('title-session-a'));
      EditableText editableName() => tester.widget<EditableText>(
        find.descendant(of: name, matching: find.byType(EditableText)),
      );
      final nameController = editableName().controller;
      await tester.enterText(name, '更新后的组件名称');
      await tester.pumpAndSettle();
      expect(workspace.findWidget('session-a')!.title, '更新后的组件名称');
      workspace.undo();
      await tester.pumpAndSettle();
      expect(editableName().controller.text, 'session-a');
      workspace.redo();
      await tester.pumpAndSettle();
      expect(editableName().controller.text, '更新后的组件名称');
      expect(identical(editableName().controller, nameController), isTrue);
      expect(editableName().focusNode.hasFocus, isTrue);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(selected('会话信息'), 'compact');
      expect(selected('已授权来源'), 'codex.sessions');
      expect(field('显示范围'), findsNothing);
      expect(find.text('最多显示会话数 · 20 个'), findsOneWidget);
      expect(inspectorScroll().position.pixels, 0);
      await tester.drag(
        find.byType(SingleChildScrollView).last,
        const Offset(0, -350),
      );
      await tester.pumpAndSettle();
      final aOffset = inspectorScroll().position.pixels;
      expect(aOffset, greaterThan(0));
      await open('quota');
      expect(selected('用量内容'), 'quota');
      expect(selected('内容布局'), 'fill');
      expect(selected('内容对齐'), 'spaceEvenly');
      expect(find.text('显示详细数据'), findsNothing);
      expect(selected('已授权来源'), 'codex.quota');
      expect(selected('显示范围'), 'weekly');
      expect(inspectorScroll().position.pixels, 0);
      await open('shortcut');
      expect(selected('已授权来源'), 'host.shortcuts');
      expect(selected('显示范围'), 'shortcut');
      expect(selected('图标尺寸'), 'fixed');
      expect(selected('行数'), 'auto');
      expect(selected('对齐方式'), 'spaceEvenly');
      expect(inspectorScroll().position.pixels, 0);
      await open('session-b');
      expect(selected('会话信息'), 'normal');
      expect(selected('已授权来源'), 'codex.sessions');
      expect(field('显示范围'), findsNothing);
      expect(find.text('最多显示会话数 · 20 个'), findsOneWidget);
      await tester.ensureVisible(field('会话信息'));
      await tester.pumpAndSettle();
      await tester.tap(field('会话信息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('精简').last);
      await tester.pumpAndSettle();
      expect(workspace.findWidget('session-b')!.options['density'], 'compact');
      expect(workspace.findWidget('session-a')!.options['itemWidth'], 240);
      expect(
        workspace.findWidget('session-a')!.binding['resourceId'],
        'session',
      );
      workspace.undo();
      await tester.pumpAndSettle();
      expect(selected('会话信息'), 'normal');
      await open('api');
      expect(selected('用量内容'), 'api');
      expect(selected('内容布局'), 'fill');
      expect(selected('内容对齐'), 'spaceEvenly');
      expect(selected('已授权来源'), 'sub2api.usage');
      expect(selected('显示范围'), 'api-account');
      final sourceRect = tester.getRect(field('已授权来源'));
      final rangeRect = tester.getRect(field('显示范围'));
      final contentRect = tester.getRect(field('用量内容'));
      final densityRect = tester.getRect(field('内容布局'));
      final alignmentRect = tester.getRect(field('内容对齐'));
      expect(rangeRect.top, greaterThanOrEqualTo(sourceRect.bottom + 8));
      expect(densityRect.top, greaterThanOrEqualTo(contentRect.bottom + 8));
      expect(alignmentRect.top, greaterThanOrEqualTo(densityRect.bottom + 8));
      expect(inspectorScroll().position.pixels, 0);
      await open('quota');
      expect(selected('用量内容'), 'quota');
      expect(selected('显示范围'), 'weekly');
      await open('session-a');
      expect(selected('会话信息'), 'compact');
      expect(field('显示范围'), findsNothing);
      expect(find.text('最多显示会话数 · 20 个'), findsOneWidget);
      expect(inspectorScroll().position.pixels, aOffset);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('inspector scroll is independent from existing content scroll', (
    tester,
  ) async {
    final value = snapshot();
    final original = Map<String, dynamic>.from(
      (value['sessions'] as List).first as Map,
    );
    value['sessions'] = <dynamic>[
      for (var i = 0; i < 30; i++)
        {...original, 'session_id': 'session-$i', 'title': '任务 $i'},
    ];
    final connection = Connection()
      ..data = WorkbenchData(value)
      ..phase = ConnectionPhase.online;
    addTearDown(connection.dispose);
    final workspace = LayoutWorkspace(
      document: LayoutDocument(
        activePageId: 'sessions',
        pages: [
          LayoutPage(
            id: 'sessions',
            name: '会话',
            widgets: [
              LayoutWidget(
                id: 'list',
                type: 'sessions',
                binding: const {'hostId': 'host', 'source': 'codex.sessions'},
                options: {
                  ...LayoutWorkspace.defaultOptions('sessions'),
                  'fitRows': false,
                  'itemHeight': 140.0,
                },
                placements: {
                  LayoutOrientation.wide: GridPlacement(
                    x: 0,
                    y: 0,
                    w: 12,
                    h: 12,
                  ).scaled(4),
                  LayoutOrientation.portrait: GridPlacement(
                    x: 0,
                    y: 0,
                    w: 4,
                    h: 24,
                  ).scaled(4),
                },
              ),
            ],
          ),
        ],
      ),
    );
    addTearDown(workspace.dispose);
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: rawBlockTheme(),
        home: Scaffold(
          body: WorkbenchCanvas(
            allowEditing: true,
            previewSize: const Size(800, 360),
            connection: connection,
            workspace: workspace,
            repository: MemoryLayouts(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final grid = find.byKey(const PageStorageKey('sessions-list'));
    ScrollableState sourceScroll() => tester.state<ScrollableState>(
      find.descendant(of: grid, matching: find.byType(Scrollable)).first,
    );
    sourceScroll().position.jumpTo(240);
    await tester.pumpAndSettle();
    expect(sourceScroll().position.pixels, greaterThan(0));
    final background = find.byKey(
      const ValueKey('page-edit-background-sessions'),
    );
    await tester.longPressAt(
      tester.getTopLeft(background) + const Offset(.25, .25),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置会话').last);
    await tester.pumpAndSettle();
    final inspector = find.byKey(const PageStorageKey('widget-inspector-list'));
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(of: inspector, matching: find.byType(Scrollable))
              .first,
        )
        .position;
    expect(position.pixels, 0);
    expect(
      find.byKey(const ValueKey('title-list')).hitTestable(),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('显示组件'));
    await tester.pumpAndSettle();
    expect(find.text('显示组件').hitTestable(), findsOneWidget);
    expect(sourceScroll().position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'all-page draft cancellation, duplicate instances and undo remain independent',
    (tester) async {
      final workspace = LayoutWorkspace();
      addTearDown(workspace.dispose);
      await launch(tester, workspace);
      workspace.beginEdit();
      workspace.addPage(name: '实验');
      final first = workspace.addWidget('usage');
      final second = workspace.addWidget('usage');
      await tester.pumpAndSettle();
      expect(first, isNot(second));
      workspace.updateWidget(first!, options: {'content': 'api'});
      workspace.renamePage('page-main', '改变名称');
      workspace.setActivePage('page-main');
      workspace.setWidgetVisible('main-shortcuts', false);
      await tester.pumpAndSettle();
      expect(workspace.findWidget(second)!.options['content'], 'quota');
      workspace.undo();
      expect(workspace.findWidget('main-shortcuts')!.visible, isTrue);
      workspace.redo();
      expect(workspace.findWidget('main-shortcuts')!.visible, isFalse);
      workspace.cancelEdit();
      await tester.pumpAndSettle();
      expect(workspace.pages.length, 3);
      expect(workspace.pages.first.name, '总览');
      expect(workspace.findWidget(first), isNull);
      expect(workspace.findWidget('main-shortcuts')!.visible, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'debounced auto-save retains draft on error and retries without leaving edit mode',
    (tester) async {
      final workspace = LayoutWorkspace();
      final repository = MemoryLayouts()..fail = true;
      addTearDown(workspace.dispose);
      await launch(tester, workspace, repository: repository);
      workspace.beginEdit();
      workspace.renamePage('page-main', '保存测试');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(workspace.editing, isTrue);
      expect(find.textContaining('布局更新失败'), findsOneWidget);
      repository.fail = false;
      repository.pending = Completer<void>();
      workspace.renamePage('page-main', '再次更新');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('更新中…'), findsOneWidget);
      expect(workspace.editing, isTrue);
      workspace.renamePage('page-main', '持续编辑');
      repository.pending!.complete();
      await tester.pumpAndSettle();
      expect(workspace.editing, isTrue);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(repository.saved!.pages.first.name, '持续编辑');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(workspace.editing, isFalse);
      expect(workspace.committed.toJson(), repository.saved!.toJson());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'small API widget keeps stale semantics and details; unknown resource is explicit',
    (tester) async {
      final value = snapshot();
      final now = value['server_time'] as int;
      (value['sources'] as List).add({
        'source_id': 'sub2api.usage',
        'health': 'ready',
        'message': '',
        'observed_at': now - 2,
        'fresh_until': now + 20,
      });
      value['api_usage'] = [
        {
          'id': 'account',
          'label': '今日API',
          'actual_cost_micros': 12340000,
          'currency': 'USD',
          'token_count': 1200000,
          'tpm': 4500,
          'window_start': now - 10000,
          'window_end': now - 1,
        },
      ];
      final connection = Connection()
        ..phase = ConnectionPhase.online
        ..data = WorkbenchData(value);
      addTearDown(connection.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 160,
                child: WorkbenchWidgetBody(
                  connection: connection,
                  id: 'api',
                  type: 'usage',
                  options: const {'content': 'api'},
                  binding: const {},
                  debugLayout: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('USD 12.34'), findsOneWidget);
      expect(find.text('上次实际成本 · 等待刷新'), findsOneWidget);
      expect(find.text('item 主指标标题'), findsNothing);
      expect(find.text('item 主指标数值'), findsNothing);
      expect(find.text('item Token'), findsNothing);
      expect(find.text('item TPM'), findsNothing);
      expect(find.text('item 统计窗口'), findsNothing);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip).first);
      expect(tooltip.message, contains('Token 1.2M · TPM 4.5K'));
      expect(tooltip.message, contains('统计窗口'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(find.text('USD 12.34')),
      );
      await tester.pumpAndSettle();
      expect(find.text('item 主指标数值'), findsOneWidget);
      await mouse.removePointer();
      await tester.longPress(find.text('USD 12.34'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Token 1.2M · TPM 4.5K'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: WorkbenchWidgetBody(
              connection: connection,
              id: 'missing',
              type: 'usage',
              options: const {},
              binding: const {'resourceId': 'deleted'},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('不在共享范围'), findsOneWidget);
    },
  );
}
