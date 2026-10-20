import 'package:deskbar/connection.dart';
import 'package:deskbar/layout_repository.dart';
import 'package:deskbar/layout_workspace.dart';
import 'package:deskbar/rawblock.dart';
import 'package:deskbar/workbench_canvas.dart';
import 'package:deskbar/workbench_content.dart';
import 'package:deskbar/workbench_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'workbench_fixture.dart';

class _Layouts extends LayoutRepository {
  @override
  Future<void> save(LayoutDocument document) async {}
}

void main() {
  testWidgets(
    'presets are one undoable change and precision settings start folded',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connection = Connection()..data = WorkbenchData(snapshot());
      final workspace = LayoutWorkspace();
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
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
      await tester.tap(find.byKey(const ValueKey('outline-main-sessions')));
      await tester.pumpAndSettle();
      expect(find.text('高级设置'), findsOneWidget);
      expect(find.widgetWithText(TextField, '卡片目标宽度'), findsNothing);
      workspace.updateWidget(
        'main-sessions',
        binding: {'hostId': 'host', 'source': 'codex.sessions'},
      );
      await tester.pumpAndSettle();
      final before = workspace.findWidget('main-sessions')!.toJson();
      await tester.tap(find.widgetWithText(ChoiceChip, '大字'));
      await tester.pumpAndSettle();
      final changed = workspace.findWidget('main-sessions')!;
      expect(changed.options['textScale'], 1.35);
      expect(changed.options['itemHeight'], 144);
      expect(changed.binding, before['binding']);
      workspace.undo();
      await tester.pumpAndSettle();
      expect(workspace.findWidget('main-sessions')!.toJson(), before);
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '卡片目标宽度'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('outline-main-shortcuts')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '横向间距'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '图文'));
      await tester.pumpAndSettle();
      expect(workspace.findWidget('main-shortcuts')!.options['labels'], true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      workspace.dispose();
      connection.dispose();
    },
  );

  for (final height in [88.0, 144.0]) {
    testWidgets('session footer stays inside a $height card with large text', (
      tester,
    ) async {
      final data = snapshot();
      final connection = Connection()
        ..data = WorkbenchData(data)
        ..phase = ConnectionPhase.online;
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 360,
                  height: height + 8,
                  child: WorkbenchWidgetBody(
                    connection: connection,
                    id: 'sessions',
                    type: 'sessions',
                    options: const {
                      'density': 'compact',
                      'appearance': 'cards',
                      'textScale': 1.35,
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
      final card = tester.getRect(
        find.byKey(const ValueKey('session-card-sessions-session')),
      );
      for (final target in [
        find.text((data['sessions'] as List).first['title'] as String),
        find.byKey(const ValueKey('session-project-sessions-session')),
        find.byKey(const ValueKey('session-time-sessions-session')),
      ]) {
        final rect = tester.getRect(target);
        expect(rect.top, greaterThanOrEqualTo(card.top));
        expect(rect.bottom, lessThanOrEqualTo(card.bottom));
        expect(rect.left, greaterThanOrEqualTo(card.left));
        expect(rect.right, lessThanOrEqualTo(card.right));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      connection.dispose();
    });
  }

  for (final size in [
    const Size(220, 300),
    const Size(300, 180),
    const Size(640, 140),
    const Size(180, 420),
    const Size(220, 90),
  ]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('quota keeps visible information inside $size at $scale', (
        tester,
      ) async {
        final connection = Connection()
          ..data = WorkbenchData(snapshot())
          ..phase = ConnectionPhase.online;
        final bounds = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: rawBlockTheme(),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    key: bounds,
                    width: size.width,
                    height: size.height,
                    child: WorkbenchWidgetBody(
                      connection: connection,
                      id: 'quota',
                      type: 'usage',
                      options: const {'density': 'sidebar'},
                      binding: const {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final area = tester.getRect(find.byKey(bounds));
        for (final key in [
          'usage-number-quota',
          'quota-reset',
          'quota-countdown',
          'quota-reset-summary',
        ]) {
          final target = find.byKey(ValueKey(key));
          if (target.evaluate().isEmpty) continue;
          final rect = tester.getRect(target);
          expect(rect.top, greaterThanOrEqualTo(area.top - .1));
          expect(rect.bottom, lessThanOrEqualTo(area.bottom + .1));
          expect(rect.left, greaterThanOrEqualTo(area.left - .1));
          expect(rect.right, lessThanOrEqualTo(area.right + .1));
        }
        expect(find.text('43%'), findsOneWidget);
        if (size.height >= 120 * scale) {
          expect(find.byKey(const ValueKey('quota-reset')), findsOneWidget);
          expect(find.byKey(const ValueKey('quota-countdown')), findsOneWidget);
        } else if (size.height >= 64 * scale) {
          expect(
            find.byKey(const ValueKey('quota-reset-summary')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        connection.dispose();
      });
    }
  }
}
