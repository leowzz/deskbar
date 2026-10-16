import 'dart:async';
import 'package:desklet/connection.dart';
import 'package:desklet/display_preferences.dart';
import 'package:desklet/layout_repository.dart';
import 'package:desklet/layout_workspace.dart';
import 'package:desklet/rawblock.dart';
import 'package:desklet/workbench_canvas.dart';
import 'package:desklet/workbench_content.dart';
import 'package:desklet/workbench_data.dart';
import 'package:flutter/material.dart';
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
  Size size = const Size(360, 640),
  double scale = 1,
  Brightness brightness = Brightness.light,
  MemoryLayouts? repository,
  bool withChrome = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final connection = Connection()
    ..phase = ConnectionPhase.online
    ..hostName = '工作电脑'
    ..data = WorkbenchData(snapshot());
  addTearDown(connection.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: rawBlockTheme(brightness),
      home: Scaffold(
        appBar: withChrome ? AppBar(title: const Text('Desklet 工作台')) : null,
        body: SafeArea(
          child: Column(
            children: [
              if (withChrome && size.height > size.width)
                const SizedBox(height: 54),
              Expanded(
                child: WorkbenchCanvas(
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

void main() {
  for (final size in [
    const Size(360, 640),
    const Size(800, 360),
    const Size(320, 480),
    const Size(480, 280),
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
          expect(find.text('卡片目标宽度 · 280 dp'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
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
            matching: find.text('Desklet'),
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
          matching: find.text('Desklet'),
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
      expect(find.textContaining('长按调整组件大小'), findsOneWidget);
      expect(find.byType(GridView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'normal immersive canvas has only content and long press enters edit',
    (tester) async {
      final workspace = LayoutWorkspace();
      addTearDown(workspace.dispose);
      await launch(tester, workspace);
      expect(find.byTooltip('编辑布局'), findsNothing);
      expect(find.byTooltip('沉浸显示'), findsNothing);
      expect(find.byIcon(Icons.fullscreen), findsNothing);
      expect(find.byIcon(Icons.fullscreen_exit), findsNothing);
      expect(find.text('1'), findsNothing);
      expect(find.text('总览'), findsNothing);
      expect(find.text('近期会话'), findsNothing);
      expect(
        find.byKey(const ValueKey('widget-edit-frame-main-sessions')),
        findsNothing,
      );
      final background = find.byKey(
        const ValueKey('page-edit-background-page-main'),
      );
      await tester.longPressAt(
        tester.getTopLeft(background) + const Offset(.25, .25),
      );
      await tester.pumpAndSettle();
      expect(workspace.editing, isTrue);
      expect(find.text('完成').hitTestable(), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('widget-edit-frame-main-sessions')),
        findsOneWidget,
      );
    },
  );
  for (final scale in [1.0, 1.8]) {
    testWidgets(
      'landscape inspector leaves canvas and finish/cancel reachable scale $scale',
      (tester) async {
        final workspace = LayoutWorkspace()..beginEdit();
        addTearDown(workspace.dispose);
        await launch(
          tester,
          workspace,
          size: const Size(480, 280),
          scale: scale,
        );
        await tester.tap(find.byTooltip('设置会话').first);
        await tester.pumpAndSettle();
        expect(find.text('完成').hitTestable(), findsOneWidget);
        expect(find.text('取消').hitTestable(), findsOneWidget);
        expect(find.byTooltip('关闭设置').hitTestable(), findsOneWidget);
        final canvas = tester.getRect(find.byType(PageView));
        final inspector = tester.getRect(
          find.byType(SingleChildScrollView).last,
        );
        expect(canvas.width, greaterThan(100));
        expect(canvas.height, greaterThan(100));
        expect(canvas.right, lessThanOrEqualTo(inspector.left + 1));
        expect(find.text('显示标题'), findsNothing);
        expect(find.text('临时铺满'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭设置'));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(PageView)).width, 480);
        expect(find.text('完成').hitTestable(), findsOneWidget);
      },
    );
  }
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
              ),
              LayoutOrientation.portrait: GridPlacement(
                x: 0,
                y: i * 4,
                w: 4,
                h: 4,
              ),
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
        final frame = find.byKey(ValueKey('widget-edit-frame-$id'));
        await tester.tap(
          find.descendant(of: frame, matching: find.byIcon(Icons.tune)).last,
        );
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
      expect(selected('已授权来源'), 'codex.quota');
      expect(selected('显示范围'), 'weekly');
      expect(inspectorScroll().position.pixels, 0);
      await open('shortcut');
      expect(selected('已授权来源'), 'host.shortcuts');
      expect(selected('显示范围'), 'shortcut');
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
      expect(selected('已授权来源'), 'sub2api.usage');
      expect(selected('显示范围'), 'api-account');
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
  testWidgets(
    'first inspector starts at top after source content has scrolled',
    (tester) async {
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
                  placements: const {
                    LayoutOrientation.wide: GridPlacement(
                      x: 0,
                      y: 0,
                      w: 12,
                      h: 12,
                    ),
                    LayoutOrientation.portrait: GridPlacement(
                      x: 0,
                      y: 0,
                      w: 4,
                      h: 24,
                    ),
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
      await tester.drag(grid, const Offset(0, -240));
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
      final inspector = find.byKey(
        const PageStorageKey('widget-inspector-list'),
      );
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
      expect(find.text('显示组件').hitTestable(), findsOneWidget);
      expect(sourceScroll().position.pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'legacy one-cell component stays recoverable and default bindings stick to first host',
    (tester) async {
      final tiny = LayoutWidget(
        id: 'tiny',
        type: 'sessions',
        placements: {
          for (final o in LayoutOrientation.values)
            o: const GridPlacement(x: 0, y: 0, w: 1, h: 1),
        },
      );
      final workspace = LayoutWorkspace(
        document: LayoutDocument(
          activePageId: 'tiny-page',
          pages: [
            LayoutPage(id: 'tiny-page', name: '小区域', widgets: [tiny]),
          ],
        ),
      );
      addTearDown(workspace.dispose);
      final repository = MemoryLayouts();
      await launch(
        tester,
        workspace,
        size: const Size(480, 280),
        scale: 1.8,
        repository: repository,
      );
      expect(workspace.findWidget('tiny')!.binding['hostId'], 'host');
      expect(workspace.findWidget('tiny')!.binding['source'], 'codex.sessions');
      expect(
        repository.saved!.pages.first.widgets.first.binding['hostId'],
        'host',
      );
      expect(tester.takeException(), isNull);
      workspace.beginEdit();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置会话').first);
      await tester.pumpAndSettle();
      expect(find.text('会话设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
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
    'save error retains draft, retry saves it, save locks back and gestures',
    (tester) async {
      final workspace = LayoutWorkspace();
      final repository = MemoryLayouts()..fail = true;
      addTearDown(workspace.dispose);
      await launch(tester, workspace, repository: repository);
      workspace.beginEdit();
      workspace.renamePage('page-main', '保存测试');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('完成'));
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(workspace.editing, isTrue);
      expect(find.textContaining('草稿仍保留'), findsOneWidget);
      repository.fail = false;
      repository.pending = Completer<void>();
      await tester.tap(find.text('完成'));
      await tester.pump();
      expect(find.text('保存中…'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(workspace.editing, isTrue);
      repository.pending!.complete();
      await tester.pumpAndSettle();
      expect(workspace.editing, isFalse);
      expect(repository.saved!.pages.first.name, '保存测试');
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
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('USD 12.34'), findsOneWidget);
      expect(find.text('上次实际成本 · 等待刷新'), findsOneWidget);
      await tester.tap(find.text('USD 12.34'));
      await tester.pumpAndSettle();
      expect(find.text('API 用量详情'), findsOneWidget);
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
