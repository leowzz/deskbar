import 'dart:async';
import 'package:desklet/main.dart';
import 'package:desklet/rawblock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('app.desklet/connection'),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('app.desklet/events'),
      (call) async => null,
    );
  });
  testWidgets(
    'defaults to silver, persists graphite and restores after restart',
    (tester) async {
      String? preference;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app.desklet/layout'), (
            call,
          ) async {
            if (call.method == 'saveTheme') {
              preference = (call.arguments as Map)['theme'] as String;
            }
            return call.method == 'loadTheme' ? preference : null;
          });
      await tester.pumpWidget(const DeskletApp());
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.light,
      );
      expect(
        Theme.of(
          tester.element(find.byType(Scaffold)),
        ).extension<DeskletColors>()!.canvas,
        DeskletColors.silver.canvas,
      );
      await tester.tap(find.byTooltip('切换暗色主题'));
      await tester.pumpAndSettle();
      expect(preference, 'dark');
      expect(
        Theme.of(
          tester.element(find.byType(Scaffold)),
        ).extension<DeskletColors>()!.canvas,
        DeskletColors.graphite.canvas,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const DeskletApp());
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('late preference restore does not replace a user theme choice', (
    tester,
  ) async {
    final load = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.desklet/layout'),
          (call) async => call.method == 'loadTheme' ? load.future : null,
        );
    await tester.pumpWidget(const DeskletApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换暗色主题'));
    await tester.pumpAndSettle();
    load.complete('light');
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
