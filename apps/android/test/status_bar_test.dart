import 'dart:io';
import 'dart:ui' as ui;
import 'package:deskbar/connection.dart';
import 'package:deskbar/dashboard_widgets.dart';
import 'package:deskbar/rawblock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('status bar anchors clock, name and actions independently', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await (FontLoader(
      'Noto Sans SC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final connection = Connection()..phase = ConnectionPhase.online;
    addTearDown(connection.dispose);
    final boundary = GlobalKey();
    for (final scenario in [
      (
        name: 'wide',
        size: const Size(1100, 64),
        label: 'DeskBar',
        actions: true,
        scale: 1.0,
      ),
      (
        name: 'long-name',
        size: const Size(800, 64),
        label: '办公室电脑工作台名称很长时仍然保持时间居中',
        actions: true,
        scale: 1.0,
      ),
      (
        name: 'no-name',
        size: const Size(800, 64),
        label: '',
        actions: true,
        scale: 1.0,
      ),
      (
        name: 'no-actions',
        size: const Size(800, 64),
        label: 'DeskBar',
        actions: false,
        scale: 1.0,
      ),
      (
        name: 'narrow',
        size: const Size(360, 100),
        label: 'DeskBar',
        actions: true,
        scale: 1.0,
      ),
      (
        name: 'short',
        size: const Size(480, 48),
        label: '',
        actions: true,
        scale: 1.0,
      ),
      (
        name: 'large-text',
        size: const Size(640, 100),
        label: 'DeskBar',
        actions: true,
        scale: 1.8,
      ),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: rawBlockTheme(
            scenario.name == 'narrow' ? Brightness.dark : Brightness.light,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: scenario.size.width,
                  height: scenario.size.height,
                  child: MediaQuery(
                    data: MediaQueryData(
                      textScaler: TextScaler.linear(scenario.scale),
                    ),
                    child: WorkbenchStatusBar(
                      connection: connection,
                      options: {
                        'label': scenario.label,
                        'showConnection': scenario.actions,
                        'showThemeButton': scenario.actions,
                        'showSettingsButton': scenario.actions,
                      },
                      onTheme: () {},
                      onSettings: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final clock = tester.getRect(
        find.byKey(const ValueKey('status-bar-clock')),
      );
      expect(
        clock.center.dx,
        closeTo(scenario.size.width / 2, 0.01),
        reason: scenario.name,
      );
      if (scenario.label.isNotEmpty) {
        final label = tester.getRect(find.text(scenario.label));
        expect(label.left, closeTo(8, 0.01));
        expect(label.right, lessThanOrEqualTo(clock.left));
      }
      if (scenario.actions) {
        final settings = tester.getRect(find.byTooltip('设置'));
        expect(settings.right, closeTo(scenario.size.width - 8, 0.01));
        final theme = tester.getRect(find.byTooltip('切换主题'));
        expect(theme.right, lessThanOrEqualTo(settings.left));
        if (clock.top < theme.bottom) {
          expect(
            clock.right,
            lessThanOrEqualTo(tester.getRect(find.byTooltip('实时连接')).left),
          );
        }
      }
      expect(tester.takeException(), isNull, reason: scenario.name);
      final folder = Platform.environment['DESKBAR_SCREENSHOT_DIR'];
      if (folder != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(folder).create(recursive: true);
          await File(
            '$folder/status-bar-${scenario.name}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
}
