import 'dart:io';
import 'dart:ui' as ui;
import 'package:deskbar/connection.dart';
import 'package:deskbar/layout_repository.dart';
import 'package:deskbar/layout_workspace.dart';
import 'package:deskbar/rawblock.dart';
import 'package:deskbar/workbench_canvas.dart';
import 'package:deskbar/workbench_content.dart';
import 'package:deskbar/workbench_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'workbench_fixture.dart';

Map<String, dynamic> manySessions() {
  final data = snapshot();
  final original = Map<String, dynamic>.from(
    (data['sessions'] as List).single as Map,
  );
  data['sessions'] = [
    for (var i = 0; i < 14; i++)
      {
        ...original,
        'session_id': 's$i',
        'title': '会话 $i · 优化工作台组件显示',
        'project': 'DeskBar',
        'repo': 'deskbar',
        'branch': 'main',
        'model': 'gpt-6.1-sol',
        'reasoning_effort': 'high',
      },
  ];
  final now = data['server_time'] as int;
  (data['sources'] as List).add({
    'source_id': 'sub2api.usage',
    'health': 'ready',
    'message': '',
    'observed_at': now,
    'fresh_until': now + 120,
  });
  data['api_usage'] = [
    {
      'id': 'api',
      'label': '今日用量',
      'currency': 'USD',
      'actual_cost_micros': 12340000,
      'token_count': 1200000,
      'tpm': 4500,
      'window_start': now - 3600,
      'window_end': now + 3600,
    },
  ];
  return data;
}

class _Layouts extends LayoutRepository {
  @override
  Future<void> save(LayoutDocument document) async {}
}

void main() {
  testWidgets(
    'sessions scroll continuously through refresh and visible count changes',
    (tester) async {
      final data = manySessions();
      final connection = Connection()
        ..data = WorkbenchData(data)
        ..phase = ConnectionPhase.online;
      addTearDown(connection.dispose);
      Future<void> mount(int count) => tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 360,
              child: WorkbenchWidgetBody(
                connection: connection,
                id: 'sessions',
                type: 'sessions',
                options: {'columns': 2, 'maxSessions': count},
                binding: const {},
              ),
            ),
          ),
        ),
      );
      await mount(6);
      final gridFinder = find.byType(GridView);
      GridView grid() => tester.widget<GridView>(gridFinder);
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find.descendant(of: gridFinder, matching: find.byType(Scrollable)),
          )
          .position;
      expect(grid().childrenDelegate.estimatedChildCount, 14);
      expect(find.byTooltip('下一页会话'), findsNothing);
      final firstExtent =
          (grid().gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .mainAxisExtent!;
      final viewport = tester.getRect(gridFinder);
      final sixth = tester.getRect(
        find.byKey(const ValueKey('session-card-sessions-s5')),
      );
      expect(sixth.bottom, closeTo(viewport.bottom, .1));
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('session-card-sessions-s13')),
        gridFinder,
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      final offset = position().pixels;
      expect(offset, greaterThan(0));
      await mount(6);
      await tester.pumpAndSettle();
      expect(position().pixels, closeTo(offset, .1));
      data['sessions'] = (data['sessions'] as List).take(7).toList();
      connection.data = WorkbenchData(data);
      await mount(6);
      await tester.pumpAndSettle();
      expect(grid().childrenDelegate.estimatedChildCount, 7);
      expect(position().pixels, lessThanOrEqualTo(position().maxScrollExtent));
      await mount(4);
      await tester.pumpAndSettle();
      expect(grid().childrenDelegate.estimatedChildCount, 7);
      expect(
        (grid().gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .mainAxisExtent,
        greaterThan(firstExtent),
      );
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('session-card-sessions-s6')),
        gridFinder,
        const Offset(0, -250),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('session details adapt and absent metadata stays absent', (
    tester,
  ) async {
    final data = manySessions();
    data['sessions'] = [(data['sessions'] as List).first];
    final connection = Connection()
      ..data = WorkbenchData(data)
      ..phase = ConnectionPhase.online;
    addTearDown(connection.dispose);
    for (final size in [const Size(360, 88), const Size(180, 180)]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(
                size: size,
                child: WorkbenchWidgetBody(
                  connection: connection,
                  id: 'detail',
                  type: 'sessions',
                  options: const {'columns': 1, 'maxSessions': 1},
                  binding: const {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('deskbar · main'), findsOneWidget);
      expect(find.text('gpt-6.1-sol · high'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('session-time-detail-s0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
    final old = WorkbenchData(snapshot()).sessions.single;
    expect(
      [old.repo, old.branch, old.model, old.reasoningEffort],
      ['', '', '', ''],
    );
  });

  for (final size in [
    const Size(120, 48),
    const Size(220, 90),
    const Size(180, 420),
    const Size(300, 180),
    const Size(640, 100),
    const Size(960, 480),
  ]) {
    for (final scale in [1.0, 1.8]) {
      for (final online in [true, false]) {
        testWidgets('components fit $size scale=$scale online=$online', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(1100, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final data = manySessions();
          final shortcut = Map<String, dynamic>.from(
            (data['shortcuts'] as List).single as Map,
          );
          data['shortcuts'] = [
            for (var i = 0; i < 24; i++)
              {...shortcut, 'shortcut_id': 'entry-$i'},
          ];
          final connection = Connection()
            ..data = WorkbenchData(data)
            ..phase = online ? ConnectionPhase.online : ConnectionPhase.offline;
          for (final type in [
            'sessions',
            'shortcuts',
            'quota',
            'api',
            'statusBar',
          ]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: rawBlockTheme(
                  online ? Brightness.light : Brightness.dark,
                ),
                home: Scaffold(
                  body: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: size.width,
                        height: size.height,
                        child: WorkbenchWidgetBody(
                          key: ValueKey(type),
                          connection: connection,
                          id: type,
                          type: ['quota', 'api'].contains(type)
                              ? 'usage'
                              : type,
                          options: {
                            'columns': 2,
                            'maxSessions': 6,
                            'labels': true,
                            'content': type,
                            // Legacy fine-grained settings must no longer distort rendering.
                            'itemWidth': 999,
                            'itemHeight': 400,
                            'textScale': 2,
                            'gapX': 64,
                            'gapY': 64,
                            'iconSize': 200,
                            'density': 'compact',
                          },
                          binding: const {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            expect(tester.takeException(), isNull, reason: type);
            if (type == 'quota' || type == 'api') {
              final area = tester.getRect(find.byType(WorkbenchWidgetBody));
              final value = tester.getRect(
                find.byKey(ValueKey('usage-number-$type')),
              );
              expect(area.inflate(.1).contains(value.topLeft), isTrue);
              expect(area.inflate(.1).contains(value.bottomRight), isTrue);
            }
          }
          await tester.pumpWidget(const SizedBox());
          connection.dispose();
        });
      }
    }
  }

  testWidgets('overview and editor render with automatic components', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1360, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final loader = FontLoader('Noto Sans SC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final workspace = LayoutWorkspace()..beginEdit();
    workspace.addDashboardPage(hostId: 'host');
    workspace.commitEdit();
    final connection = Connection()
      ..data = WorkbenchData({
        ...manySessions(),
        'layout': workspace.document.toJson(),
      })
      ..phase = ConnectionPhase.online;
    final boundary = GlobalKey();
    Future<void> capture(String name) async {
      final folder = Platform.environment['DESKBAR_SCREENSHOT_DIR'];
      if (folder == null) return;
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(folder).create(recursive: true);
        await File(
          '$folder/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final editor in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundary,
              child: ColoredBox(
                color: const Color(0xFFF6F7F9),
                child: WorkbenchCanvas(
                  key: ValueKey(editor),
                  connection: connection,
                  workspace: workspace,
                  repository: _Layouts(),
                  allowEditing: editor,
                  previewSize: editor ? const Size(1280, 720) : null,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (editor) {
        final session = workspace.activePage.widgets.firstWhere(
          (w) => w.type == 'sessions',
        );
        await tester.tap(find.byKey(ValueKey('outline-${session.id}')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, '每屏会话数'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await capture(editor ? 'editor' : 'overview');
      if (editor) {
        await tester.tap(find.text('高级设置'));
        await tester.pumpAndSettle();
        void expectLabelInsideExpansion() {
          final label = find.text('组件名称');
          final labelRect = tester.getRect(label);
          final clip = find
              .ancestor(of: label, matching: find.byType(ClipRect))
              .first;
          expect(labelRect.top, greaterThanOrEqualTo(tester.getRect(clip).top));
          expect(
            labelRect.top,
            greaterThan(tester.getRect(find.text('名称、位置与来源')).bottom + 8),
          );
        }

        expectLabelInsideExpansion();
        await capture('editor-expanded');
        tester.view.physicalSize = const Size(800, 720);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectLabelInsideExpansion();
        await capture('editor-expanded-narrow');
      }
    }
    await tester.pumpWidget(const SizedBox());
    connection.dispose();
    workspace.dispose();
  });
}
