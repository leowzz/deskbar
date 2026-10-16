import 'dart:convert';

import 'package:deskbar/connection.dart';
import 'package:deskbar/layout_repository.dart';
import 'package:deskbar/layout_workspace.dart';
import 'package:deskbar/rawblock.dart';
import 'package:deskbar/workbench_canvas.dart';
import 'package:deskbar/workbench_data.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbench_fixture.dart';

class _MemoryRepository extends LayoutRepository {
  _MemoryRepository(this.document, {this.readOnly = false});
  LayoutDocument document;
  final bool readOnly;
  int saves = 0;
  @override
  Future<LayoutLoadResult> load() async => LayoutLoadResult(
    document: document,
    readOnly: readOnly,
    warning: readOnly ? '布局来自较新版本，请升级工作台后再编辑；原配置已保留' : null,
  );
  @override
  Future<void> save(LayoutDocument document) async {
    if (readOnly) throw const FormatException('较新版本布局');
    saves++;
    this.document = document;
  }
}

LayoutDocument _pages({bool hidden = false, String? hostId}) => LayoutDocument(
  activePageId: 'first',
  pages: [
    for (final (id, name, type) in [
      ('first', '第一页', 'sessions'),
      ('second', '第二页', 'usage'),
      ('third', '第三页', 'shortcuts'),
    ])
      LayoutPage(
        id: id,
        name: name,
        widgets: [
          LayoutWidget(
            id: '$id-widget',
            type: type,
            visible: !hidden,
            title: name,
            binding: {'hostId': ?hostId},
            options: {
              ...LayoutWorkspace.defaultOptions(type),
              'itemWidth': 150.0,
              'itemHeight': 140.0,
              'fitRows': false,
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
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Map<String, dynamic>> commands;
  setUp(() {
    commands = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.deskbar/connection'),
          (call) async {
            if (call.method == 'command') {
              commands.add(Map<String, dynamic>.from(call.arguments as Map));
              return jsonEncode({'message': '已打开'});
            }
            return null;
          },
        );
  });

  Future<Connection> mount(
    WidgetTester tester,
    LayoutDocument document, {
    LayoutWorkspace? workspace,
    _MemoryRepository? repository,
    bool manySessions = false,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = snapshot();
    if (manySessions) {
      final original = Map<String, dynamic>.from(
        (data['sessions'] as List).single as Map,
      );
      data['sessions'] = [
        for (var i = 0; i < 30; i++)
          {...original, 'session_id': 'session-$i', 'title': '任务 $i'},
      ];
    }
    final connection = Connection()
      ..phase = ConnectionPhase.online
      ..data = WorkbenchData(data);
    addTearDown(connection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: rawBlockTheme(),
        home: Scaffold(
          body: WorkbenchCanvas(
            connection: connection,
            workspace: workspace,
            repository: repository ?? _MemoryRepository(document),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return connection;
  }

  testWidgets(
    'horizontal drag on a session changes one page without opening it',
    (tester) async {
      final document = _pages();
      final workspace = LayoutWorkspace(document: document);
      addTearDown(workspace.dispose);
      await mount(tester, document, workspace: workspace);
      final card = find.text('一个比较长的真实工作任务标题，需要在大字号和窄屏下保持可读');
      expect(card, findsOneWidget);
      await tester.drag(card, const Offset(-620, 0));
      await tester.pumpAndSettle();
      expect(workspace.activePage.id, 'second');
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'vertical session scrolling keeps page and does not submit a click',
    (tester) async {
      final document = _pages();
      final workspace = LayoutWorkspace(document: document);
      addTearDown(workspace.dispose);
      await mount(tester, document, workspace: workspace, manySessions: true);
      final grid = find.byKey(const PageStorageKey('sessions-first-widget'));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: grid, matching: find.byType(Scrollable)),
      );
      expect(scrollable.position.pixels, 0);
      await tester.drag(find.text('任务 0'), const Offset(0, -280));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(0));
      expect(workspace.activePage.id, 'first');
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('editing consumes content taps and disables swipe paging', (
    tester,
  ) async {
    final document = _pages();
    final workspace = LayoutWorkspace(document: document)..beginEdit();
    addTearDown(workspace.dispose);
    await mount(tester, document, workspace: workspace);
    final card = find.text('一个比较长的真实工作任务标题，需要在大字号和窄屏下保持可读');
    // Editing deliberately ignores the content hit target. Touch its visual
    // position to exercise the containing widget's selection gesture instead.
    final position = tester.getRect(card).center;
    await tester.tapAt(position);
    await tester.pump();
    expect(workspace.selectedWidgetId, 'first-widget');
    await tester.dragFrom(position, const Offset(-620, 0));
    await tester.pumpAndSettle();
    expect(workspace.activePage.id, 'first');
    expect(commands, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'trackpad inertia changes once and keyboard stops at both boundaries',
    (tester) async {
      final document = _pages();
      final workspace = LayoutWorkspace(document: document);
      addTearDown(workspace.dispose);
      await mount(tester, document, workspace: workspace);
      final position = tester.getCenter(find.byType(PageView));
      for (var i = 0; i < 4; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: position,
            scrollDelta: const Offset(100, 0),
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(workspace.activePage.id, 'second');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(workspace.activePage.id, 'third');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(workspace.activePage.id, 'third');
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
      }
      expect(workspace.activePage.id, 'first');
      expect(commands, isEmpty);
    },
  );

  testWidgets('all hidden components keep long-press editing accessible', (
    tester,
  ) async {
    final document = _pages(hidden: true);
    final workspace = LayoutWorkspace(document: document);
    addTearDown(workspace.dispose);
    await mount(tester, document, workspace: workspace);
    expect(find.byTooltip('编辑布局'), findsNothing);
    await tester.longPressAt(tester.getCenter(find.byType(PageView)));
    await tester.pumpAndSettle();
    expect(workspace.editing, true);
    expect(find.text('完成'), findsOneWidget);
  });

  testWidgets('future schema remains read only through long press', (
    tester,
  ) async {
    final document = _pages();
    final repository = _MemoryRepository(document, readOnly: true);
    await mount(tester, document, repository: repository);
    expect(find.text('布局来自较新版本，请升级工作台后再编辑；原配置已保留'), findsOneWidget);
    final background = find.byKey(const ValueKey('page-edit-background-first'));
    await tester.longPressAt(
      tester.getTopLeft(background) + const Offset(.25, .25),
    );
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsNothing);
    expect(find.text('请升级工作台后再编辑布局。'), findsOneWidget);
    expect(repository.saves, 0);
  });

  testWidgets('long press on session never executes the remote action', (
    tester,
  ) async {
    final document = _pages();
    final workspace = LayoutWorkspace(document: document);
    addTearDown(workspace.dispose);
    await mount(tester, document, workspace: workspace);
    await tester.longPress(find.text('一个比较长的真实工作任务标题，需要在大字号和窄屏下保持可读'));
    await tester.pumpAndSettle();
    expect(commands, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(commands, isEmpty);
  });
  testWidgets(
    'a mismatched stable host binding cannot open current host resources',
    (tester) async {
      final document = _pages(hostId: 'different-stable-host');
      final workspace = LayoutWorkspace(document: document);
      addTearDown(workspace.dispose);
      await mount(tester, document, workspace: workspace);
      final message = find.text('此组件绑定的电脑尚未连接。可以在组件设置中更换来源。');
      expect(message, findsOneWidget);
      expect(find.text('一个比较长的真实工作任务标题，需要在大字号和窄屏下保持可读'), findsNothing);
      await tester.tap(message);
      await tester.pumpAndSettle();
      expect(commands, isEmpty);
    },
  );
}
