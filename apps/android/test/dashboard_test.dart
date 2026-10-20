import 'dart:convert';
import 'dart:io';
import 'package:deskbar/connection.dart';
import 'package:deskbar/dashboard_widgets.dart';
import 'package:deskbar/layout_workspace.dart';
import 'package:deskbar/layout_repository.dart';
import 'package:deskbar/rawblock.dart';
import 'package:deskbar/workbench_canvas.dart';
import 'package:deskbar/workbench_content.dart';
import 'package:deskbar/workbench_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'workbench_fixture.dart' as fixture;

LayoutDocument dashboard() => LayoutDocument.fromJson(
  jsonDecode(File('../../protocol/dashboard.example.json').readAsStringSync())
      as Map<String, dynamic>,
);

class DashboardRepository extends LayoutRepository {
  LayoutDocument? saved;
  @override
  Future<void> save(LayoutDocument document) async {
    saved = document;
  }
}

void main() {
  testWidgets(
    'inspector moves a status bar to the occupied overview and saves both profiles',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = LayoutWorkspace()..beginEdit();
      final source = workspace.addPage()!;
      final id = workspace.addWidget('statusBar')!;
      final connection = Connection()..data = WorkbenchData(fixture.snapshot());
      final repository = DashboardRepository();
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: WorkbenchCanvas(
              connection: connection,
              workspace: workspace,
              repository: repository,
              allowEditing: true,
              previewSize: const Size(1600, 720),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('outline-$id')));
      await tester.pumpAndSettle();
      final move = find.byKey(ValueKey('move-$id'));
      await tester.ensureVisible(move);
      await tester.tap(move);
      await tester.pumpAndSettle();
      await tester.tap(find.text('总览').last);
      await tester.pumpAndSettle();
      expect(workspace.activePage.id, 'page-main');
      await tester.pump(const Duration(seconds: 1));
      final saved = repository.saved!;
      expect(saved.pages.firstWhere((p) => p.id == source).widgets, isEmpty);
      expect(saved.activePage.widgets.where((w) => w.id == id).length, 1);
      for (final orientation in LayoutOrientation.values) {
        expect(
          saved.activePage.widgets
              .firstWhere((w) => w.id == id)
              .placementFor(orientation)
              .y,
          0,
        );
      }
      saved.validate();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      connection.dispose();
      workspace.dispose();
    },
  );

  testWidgets('editor adds template, edits status label, undoes and saves', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final workspace = LayoutWorkspace();
    final connection = Connection()..data = WorkbenchData(fixture.snapshot());
    final repository = DashboardRepository();
    await tester.pumpWidget(
      MaterialApp(
        theme: rawBlockTheme(),
        home: Scaffold(
          body: WorkbenchCanvas(
            connection: connection,
            workspace: workspace,
            repository: repository,
            allowEditing: true,
            previewSize: const Size(1600, 720),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建页面'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加横屏总览'));
    await tester.pumpAndSettle();
    expect(workspace.pages.length, 4);
    expect(workspace.activePage.widgets.length, 4);
    final status = workspace.activePage.widgets.singleWhere(
      (w) => w.type == 'statusBar',
    );
    await tester.tap(find.byKey(ValueKey('outline-${status.id}')));
    await tester.pumpAndSettle();
    final field = find.byKey(ValueKey('title-${status.id}-label'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '我的副屏');
    await tester.pump();
    expect(workspace.findWidget(status.id)!.options['label'], '我的副屏');
    workspace.undo();
    await tester.pump();
    expect(tester.widget<TextFormField>(field).controller!.text, 'DeskBar');
    workspace.redo();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(
      repository.saved!.activePage.widgets
          .singleWhere((w) => w.type == 'statusBar')
          .options['label'],
      '我的副屏',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    connection.dispose();
    workspace.dispose();
  });
  test(
    'dashboard appends atomically, survives serialization and is undoable',
    () {
      final workspace = LayoutWorkspace();
      final before = workspace.document.toJson();
      workspace.beginEdit();
      expect(workspace.addDashboardPage(hostId: 'host'), isNotNull);
      final created = workspace.activePage;
      final reloaded = LayoutDocument.fromJson(workspace.document.toJson());
      expect(reloaded.activePage.widgets.map((w) => w.type), [
        'sessions',
        'usage',
        'shortcuts',
        'statusBar',
      ]);
      final defaults = LayoutDocument.initial().activePage;
      for (final widget in created.widgets) {
        final template = defaults.widgets.singleWhere(
          (w) => w.type == widget.type,
        );
        final example = dashboard().activePage.widgets.singleWhere(
          (w) => w.type == widget.type,
        );
        expect(widget.id, isNot(template.id));
        expect(widget.binding, {
          ...template.binding,
          if (widget.type != 'statusBar') 'hostId': 'host',
        });
        expect(widget.options, template.options);
        expect(widget.options, example.options);
        for (final orientation in LayoutOrientation.values) {
          expect(
            widget.placementFor(orientation),
            template.placementFor(orientation),
          );
          expect(
            widget.placementFor(orientation),
            example.placementFor(orientation),
          );
        }
      }
      expect(
        workspace.pages.take(3).map((p) => p.toJson()),
        LayoutDocument.initial().pages.map((p) => p.toJson()),
      );
      workspace.undo();
      expect(workspace.document.toJson(), before);
      workspace.redo();
      expect(workspace.activePage.id, created.id);
      workspace.dispose();
    },
  );

  testWidgets(
    'status bar works without shared data, ticks and exposes real state',
    (tester) async {
      final connection = Connection()..phase = ConnectionPhase.online;
      var theme = 0, settings = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: SizedBox(
              height: 72,
              child: WorkbenchStatusBar(
                connection: connection,
                options: const {'label': '我的工作台'},
                onTheme: () => theme++,
                onSettings: () => settings++,
              ),
            ),
          ),
        ),
      );
      expect(find.text('我的工作台'), findsOneWidget);
      expect(find.text('实时连接'), findsOneWidget);
      final before = tester.widget<Text>(
        find.byKey(const ValueKey('status-bar-clock')),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('status-bar-clock'))),
        isNot(same(before)),
      );
      await tester.tap(find.byTooltip('切换主题'));
      await tester.tap(find.byTooltip('设置'));
      expect([theme, settings], [1, 1]);
      connection.phase = ConnectionPhase.offline;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('电脑离线'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      connection.dispose();
    },
  );

  for (final scenario in [
    (const Size(164, 240), 1.0),
    (const Size(200, 240), 1.0),
    (const Size(264, 346), 1.0),
    (const Size(164, 300), 1.8),
  ]) {
    testWidgets('narrow quota keeps three sections at $scenario', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = scenario.$2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox.fromSize(
                size: scenario.$1,
                child: QuotaSidebar(
                  quota: WorkQuota({
                    'label': '周额度',
                    'remaining_percent': 72,
                    'resets_at': 1793090400,
                  }),
                  now: 1792500000,
                  fresh: true,
                  numberKey: const ValueKey('remaining'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('quota-reset-summary')), findsNothing);
      final main = tester.getRect(find.byKey(const ValueKey('remaining')));
      final reset = tester.getRect(find.byKey(const ValueKey('quota-reset')));
      final countdown = tester.getRect(
        find.byKey(const ValueKey('quota-countdown')),
      );
      expect(main.bottom, lessThan(reset.top));
      expect(main.bottom, lessThan(countdown.top));
      expect(reset.right, lessThan(countdown.left));
      expect(find.text('重置时间'), findsOneWidget);
      expect(find.text('剩余时间'), findsOneWidget);
      final bounds = tester.getRect(find.byType(QuotaSidebar));
      for (final rect in [main, reset, countdown]) {
        expect(bounds.contains(rect.topLeft), isTrue);
        expect(bounds.contains(rect.bottomRight), isTrue);
      }
      if (scenario.$1.width <= 200) {
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('quota-countdown')))
              .style!
              .fontSize,
          lessThan(20),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final scenario in [
    (const Size(1600, 720), 1.0, Brightness.light),
    (const Size(1280, 720), 1.0, Brightness.dark),
    (const Size(800, 360), 1.4, Brightness.light),
    (const Size(360, 800), 1.8, Brightness.dark),
  ]) {
    testWidgets('dashboard fits $scenario and avoids duplicate settings', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.$1;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scenario.$2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final data = fixture.snapshot()..['layout'] = dashboard().toJson();
      final connection = Connection()
        ..data = WorkbenchData(data)
        ..phase = ConnectionPhase.online;
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(scenario.$3),
          home: Scaffold(
            body: WorkbenchCanvas(
              connection: connection,
              onTheme: () {},
              onConnectionSettings: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(WorkbenchStatusBar), findsOneWidget);
      expect(find.byTooltip('设置'), findsOneWidget);
      expect(
        find.text('重置时间').evaluate().isNotEmpty ||
            find
                .byKey(const ValueKey('quota-reset-summary'))
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      connection.dispose();
    });
  }

  testWidgets(
    'expired sidebar never presents the cached percentage as current',
    (tester) async {
      final connection = Connection()
        ..data = WorkbenchData(fixture.snapshot(expired: true))
        ..phase = ConnectionPhase.offline;
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: WorkbenchWidgetBody(
              connection: connection,
              id: 'quota',
              type: 'usage',
              options: const {'density': 'sidebar'},
              binding: const {},
            ),
          ),
        ),
      );
      expect(find.text('43%'), findsNothing);
      expect(find.text('已到重置时间'), findsOneWidget);
      expect(find.textContaining('电脑离线'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      connection.dispose();
    },
  );
}
