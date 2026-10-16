import 'dart:io';

import 'package:desklet/connection.dart';
import 'package:desklet/layout_repository.dart';
import 'package:desklet/layout_workspace.dart';
import 'package:desklet/rawblock.dart';
import 'package:desklet/workbench_canvas.dart';
import 'package:desklet/workbench_content.dart';
import 'package:desklet/workbench_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbench_fixture.dart';

LayoutDocument sessionPage() => LayoutDocument(
  activePageId: 'sessions',
  pages: [
    LayoutPage(
      id: 'sessions',
      name: '会话',
      widgets: [
        for (var i = 0; i < 2; i++)
          LayoutWidget(
            id: 'session-$i',
            type: 'sessions',
            binding: const {'hostId': 'host', 'source': 'codex.sessions'},
            // Existing layouts without the new option also default to twenty.
            options: const {'density': 'compact'},
            placements: {
              for (final orientation in LayoutOrientation.values)
                orientation: GridPlacement(
                  x: i * (orientation.columns ~/ 2),
                  y: 0,
                  w: orientation.columns ~/ 2,
                  h: orientation.rows,
                ),
            },
          ),
      ],
    ),
  ],
);

void main() {
  test(
    'session limits persist per instance and support undo and cancellation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'desklet-session-limit-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final workspace = LayoutWorkspace(document: sessionPage())..beginEdit();
      addTearDown(workspace.dispose);
      expect(LayoutWorkspace.defaultOptions('sessions')['maxSessions'], 20);
      expect(
        sessionDisplayLimit(workspace.findWidget('session-0')!.options),
        20,
      );
      expect(
        workspace.updateWidget('session-0', options: {'maxSessions': 7}),
        true,
      );
      expect(
        workspace.updateWidget('session-1', options: {'maxSessions': 13}),
        true,
      );
      workspace.undo();
      expect(
        sessionDisplayLimit(workspace.findWidget('session-1')!.options),
        20,
      );
      workspace.redo();
      await LayoutRepository(directory: directory).save(workspace.document);
      workspace.commitEdit();
      final restored = (await LayoutRepository(
        directory: directory,
      ).load()).document;
      expect(
        restored.activePage.widgets.map((w) => sessionDisplayLimit(w.options)),
        [7, 13],
      );
      workspace.beginEdit();
      workspace.updateWidget('session-0', options: {'maxSessions': 3});
      workspace.cancelEdit();
      expect(
        sessionDisplayLimit(workspace.findWidget('session-0')!.options),
        7,
      );
    },
  );

  test('session count must be a bounded positive integer', () {
    final workspace = LayoutWorkspace(document: sessionPage())..beginEdit();
    addTearDown(workspace.dispose);
    for (final invalid in [0, 41, 1.5, '20', double.infinity]) {
      expect(
        workspace.updateWidget('session-0', options: {'maxSessions': invalid}),
        false,
      );
      expect(
        sessionDisplayLimit(workspace.findWidget('session-0')!.options),
        20,
      );
    }
  });

  for (final limit in [null, 1, 7, 40]) {
    testWidgets(
      'session list honors limit $limit and ignores old single-session binding',
      (tester) async {
        final value = snapshot();
        final original = Map<String, dynamic>.from(
          (value['sessions'] as List).single as Map,
        );
        value['sessions'] = [
          for (var i = 0; i < 40; i++)
            {...original, 'session_id': 'session-$i', 'title': '会话 $i'},
        ];
        value['session_total'] = 40;
        final connection = Connection()
          ..data = WorkbenchData(value)
          ..phase = ConnectionPhase.online;
        addTearDown(connection.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: rawBlockTheme(),
            home: Scaffold(
              body: WorkbenchWidgetBody(
                connection: connection,
                id: 'sessions',
                type: 'sessions',
                options: {
                  'density': 'compact',
                  'fitRows': false,
                  'maxSessions': ?limit,
                },
                binding: const {
                  'hostId': 'host',
                  'source': 'codex.sessions',
                  'resourceId': 'session-39',
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final grid = find.byType(GridView);
        final expected = limit ?? 20;
        expect(
          tester.widget<GridView>(grid).childrenDelegate.estimatedChildCount,
          expected,
        );
        expect(find.text('会话 0'), findsOneWidget);
        await tester.dragUntilVisible(
          find.text('会话 ${expected - 1}'),
          grid,
          const Offset(0, -300),
        );
        expect(find.text('会话 ${expected - 1}'), findsOneWidget);
        expect(find.text('会话 $expected'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('session inspector edits count instead of selecting a resource', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final workspace = LayoutWorkspace(document: sessionPage())..beginEdit();
    addTearDown(workspace.dispose);
    final connection = Connection()
      ..data = WorkbenchData(snapshot())
      ..phase = ConnectionPhase.online;
    addTearDown(connection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: rawBlockTheme(),
        home: Scaffold(
          body: WorkbenchCanvas(connection: connection, workspace: workspace),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final frame = find.byKey(const ValueKey('widget-edit-frame-session-0'));
    await tester.tap(
      find.descendant(of: frame, matching: find.byIcon(Icons.tune)).last,
    );
    await tester.pumpAndSettle();
    final limit = find.descendant(
      of: find.byKey(const ValueKey('session-limit-session-0')),
      matching: find.byType(Slider),
    );
    expect(tester.widget<Slider>(limit).value, 20);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.decoration.labelText == '显示范围',
      ),
      findsNothing,
    );
    tester.widget<Slider>(limit).onChanged!(7);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(limit).value, 7);
    expect(sessionDisplayLimit(workspace.findWidget('session-1')!.options), 20);
    workspace.undo();
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(limit).value, 20);
    workspace.redo();
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(limit).value, 7);
    workspace.cancelEdit();
    await tester.pumpAndSettle();
    expect(sessionDisplayLimit(workspace.findWidget('session-0')!.options), 20);
    expect(tester.takeException(), isNull);
  });
}
