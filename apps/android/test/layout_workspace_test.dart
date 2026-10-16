import 'dart:convert';
import 'dart:math';

import 'package:deskbar/layout_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

LayoutWorkspace emptyWorkspace() => LayoutWorkspace(
  document: LayoutDocument(
    activePageId: 'main',
    pages: [LayoutPage(id: 'main', name: '工作台')],
  ),
)..beginEdit();

void main() {
  test('initial pages round-trip with valid independent orientations', () {
    final original = LayoutDocument.initial();
    original.validate();
    final restored = LayoutDocument.fromJson(
      jsonDecode(jsonEncode(original.toJson())),
    );
    expect(restored.pages.map((page) => page.name), ['总览', '任务', '应用']);
    expect(restored.toJson(), original.toJson());
  });

  test('all page edits and order changes cancel together', () {
    final workspace = emptyWorkspace();
    final original = workspace.committed.toJson();
    final first = workspace.addPage(name: '任务')!;
    final second = workspace.addPage(name: '应用')!;
    expect(workspace.pages.last.widgets, isEmpty);
    workspace.renamePage(first, '写作');
    workspace.movePage(second, 0);
    workspace.addWidget('sessions');
    workspace.deletePage('main');
    expect(workspace.pages.map((page) => page.name), ['应用', '写作']);
    workspace.cancelEdit();
    expect(workspace.document.toJson(), original);
    expect(workspace.canUndo, false);
    expect(workspace.editing, false);
  });

  test('deleting last page is rejected and page delete can be undone', () {
    final workspace = emptyWorkspace();
    expect(workspace.deletePage('main'), false);
    final id = workspace.addPage()!;
    final widgetId = workspace.addWidget('sessions')!;
    expect(workspace.deletePage(id), true);
    expect(workspace.findWidget(widgetId), isNull);
    workspace.undo();
    expect(workspace.activePage.id, id);
    expect(workspace.findWidget(widgetId), isNotNull);
    workspace.redo();
    expect(workspace.findWidget(widgetId), isNull);
  });

  test(
    'same type instances have stable independent IDs, bindings and options',
    () {
      final workspace = emptyWorkspace();
      final first = workspace.addWidget(
        'usage',
        binding: {'hostId': 'host-a', 'source': 'codex'},
      )!;
      final second = workspace.addWidget(
        'usage',
        binding: {'hostId': 'host-b', 'source': 'api'},
      )!;
      expect(first, isNot(second));
      workspace.selectWidget(first);
      workspace.updateWidget(first, title: 'API', options: {'content': 'api'});
      expect(workspace.selectedWidgetId, first);
      expect(workspace.findWidget(second)!.options['content'], 'quota');
      expect(workspace.findWidget(first)!.binding['hostId'], 'host-a');
      final page = workspace.addPage(name: '另一页')!;
      expect(workspace.moveWidgetToPage(first, page), true);
      expect(workspace.findWidget(first)!.id, first);
      expect(workspace.findWidget(first)!.options['content'], 'api');
      expect(workspace.findWidget(first)!.binding['hostId'], 'host-a');
    },
  );

  test('out-of-bounds and overlap cannot change draft or history', () {
    final workspace = emptyWorkspace();
    final a = workspace.addWidget('usage')!;
    final b = workspace.addWidget('usage')!;
    final before = workspace.document.toJson();
    expect(
      workspace.setPlacement(
        b,
        LayoutOrientation.wide,
        workspace.findWidget(a)!.placementFor(LayoutOrientation.wide),
      ),
      false,
    );
    expect(
      workspace.setPlacement(
        b,
        LayoutOrientation.wide,
        GridPlacement(x: 11, y: 0, w: 4, h: 4).scaled(4),
      ),
      false,
    );
    expect(workspace.document.toJson(), before);
    workspace.undo();
    expect(workspace.findWidget(b), isNull);
  });

  test('wide edit preserves portrait coordinates and shared options', () {
    final workspace = emptyWorkspace();
    final id = workspace.addWidget('sessions')!;
    final portrait = workspace
        .findWidget(id)!
        .placementFor(LayoutOrientation.portrait);
    workspace.setPlacement(
      id,
      LayoutOrientation.wide,
      GridPlacement(x: 1, y: 2, w: 10, h: 8).scaled(4),
    );
    workspace.updateWidget(id, options: {'itemWidth': 340, 'gap': 24});
    expect(
      workspace.findWidget(id)!.placementFor(LayoutOrientation.portrait),
      portrait,
    );
    expect(workspace.findWidget(id)!.options['itemWidth'], 340);
    workspace.document.validate();
  });

  test('add checks free space in both orientations atomically', () {
    final workspace = emptyWorkspace();
    final id = workspace.addWidget('usage')!;
    workspace.setPlacement(
      id,
      LayoutOrientation.portrait,
      GridPlacement(x: 0, y: 0, w: 4, h: 24).scaled(4),
    );
    final before = workspace.document.toJson();
    expect(workspace.addWidget('usage'), isNull);
    expect(workspace.document.toJson(), before);
    expect(workspace.error, contains('竖屏'));
  });

  test(
    'cross-page move failure in portrait preserves source and all parameters',
    () {
      final workspace = emptyWorkspace();
      final first = workspace.addWidget('usage')!;
      final target = workspace.addPage()!;
      final blocking = workspace.addWidget('usage')!;
      workspace.setPlacement(
        blocking,
        LayoutOrientation.portrait,
        GridPlacement(x: 0, y: 0, w: 4, h: 24).scaled(4),
      );
      final before = workspace.document.toJson();
      expect(workspace.moveWidgetToPage(first, target), false);
      expect(workspace.document.toJson(), before);
      expect(workspace.pages.first.widgets.single.id, first);
    },
  );

  test(
    'hidden instances retain positions and refuse conflicting restoration',
    () {
      final workspace = emptyWorkspace();
      final hidden = workspace.addWidget('usage')!;
      final placement = workspace.findWidget(hidden)!.placements;
      workspace.setWidgetVisible(hidden, false);
      final occupying = workspace.addWidget('usage')!;
      expect(workspace.setWidgetVisible(hidden, true), false);
      expect(workspace.findWidget(hidden)!.visible, false);
      expect(workspace.findWidget(hidden)!.placements, placement);
      workspace.removeWidget(occupying);
      expect(workspace.setWidgetVisible(hidden, true), true);
    },
  );

  test(
    'arranging affects only visible widgets on current page and direction',
    () {
      final workspace = emptyWorkspace();
      final first = workspace.addWidget('usage')!;
      final hidden = workspace.addWidget('usage')!;
      workspace.setWidgetVisible(hidden, false);
      workspace.setPlacement(
        first,
        LayoutOrientation.wide,
        GridPlacement(x: 8, y: 6, w: 4, h: 6).scaled(4),
      );
      final page = workspace.addPage()!;
      workspace.addWidget('shortcuts');
      final otherPage = workspace.activePage.toJson();
      final before = workspace.findWidget(first)!;
      final hiddenBefore = workspace.findWidget(hidden)!.toJson();
      workspace.arrangePage(LayoutOrientation.wide, pageId: 'main');
      expect(
        workspace.findWidget(first)!.placementFor(LayoutOrientation.wide).x,
        0,
      );
      expect(
        workspace.findWidget(first)!.placementFor(LayoutOrientation.portrait),
        before.placementFor(LayoutOrientation.portrait),
      );
      expect(workspace.findWidget(hidden)!.toJson(), hiddenBefore);
      expect(
        workspace.pages.firstWhere((item) => item.id == page).toJson(),
        otherPage,
      );
    },
  );

  test('selection, temporary focus and history are never serialized', () {
    final workspace = emptyWorkspace();
    final id = workspace.addWidget('usage')!;
    final expected = jsonEncode(workspace.document.toJson());
    workspace.selectWidget(id);
    workspace.toggleFocus(id);
    expect(jsonEncode(workspace.document.toJson()), expected);
    final committed = workspace.commitEdit();
    expect(jsonEncode(committed.toJson()), expected);
    expect(workspace.focusedWidgetId, isNull);
    expect(workspace.selectedWidgetId, isNull);
    expect(workspace.canUndo, false);
    expect(workspace.addPage(), isNull);
  });

  test('undo redo preserves whole document and a new edit clears redo', () {
    final workspace = emptyWorkspace();
    final first = workspace.addWidget('usage')!;
    final before = workspace.document.toJson();
    workspace.updateWidget(first, title: '新标题', options: {'content': 'api'});
    final changed = workspace.document.toJson();
    workspace.undo();
    expect(workspace.document.toJson(), before);
    workspace.redo();
    expect(workspace.document.toJson(), changed);
    workspace.undo();
    workspace.renamePage('main', '新页面名');
    expect(workspace.canRedo, false);
  });

  test(
    'unknown widget fields survive roundtrip and cannot be mutated externally',
    () {
      final workspace = emptyWorkspace();
      workspace.addWidget(
        'future-widget',
        options: {
          'future': {
            'list': [1, 2],
          },
        },
      );
      final json = workspace.document.toJson();
      (json['pages'] as List).first['widgets'][0]['futureField'] = {
        'keep': true,
      };
      final restored = LayoutDocument.fromJson(json);
      final unknown = restored.activePage.widgets.single;
      expect(unknown.isKnown, false);
      expect(unknown.toJson()['futureField'], {'keep': true});
      expect(
        () => (unknown.options['future']['list'] as List).add(3),
        throwsUnsupportedError,
      );
      expect(
        LayoutDocument.fromJson(restored.toJson()).toJson(),
        restored.toJson(),
      );
    },
  );

  test(
    'rejects duplicate IDs, invalid geometry and credential/path bindings',
    () {
      final workspace = emptyWorkspace();
      final id = workspace.addWidget('usage')!;
      final invalid =
          jsonDecode(jsonEncode(workspace.document.toJson()))
              as Map<String, dynamic>;
      final widgets = invalid['pages'][0]['widgets'] as List;
      widgets.add(widgets.first);
      expect(() => LayoutDocument.fromJson(invalid), throwsFormatException);
      expect(
        workspace.updateWidget(
          id,
          binding: {'path': '/Applications/Secret.app'},
        ),
        false,
      );
      expect(
        workspace.addWidget('sessions', binding: {'token': 'secret'}),
        isNull,
      );
      final zero = GridPlacement(x: 0, y: 0, w: 0, h: 1).scaled(4);
      expect(zero.fits(LayoutOrientation.wide), false);
      expect(workspace.updateWidget(id, options: {'gap': -1}), false);
      expect(workspace.updateWidget(id, options: {'itemWidth': 'bad'}), false);
      expect(workspace.updateWidget(id, options: {'showTitle': 12}), false);
    },
  );

  test(
    'shortcut display options support adaptive size, rows and alignment',
    () {
      final workspace = emptyWorkspace();
      final id = workspace.addWidget('shortcuts')!;
      expect(workspace.findWidget(id)!.options['rows'], 'auto');
      expect(workspace.findWidget(id)!.options['alignment'], 'spaceEvenly');
      expect(
        workspace.updateWidget(
          id,
          options: {'iconSize': 'max', 'rows': 3, 'alignment': 'left'},
        ),
        true,
      );
      expect(workspace.findWidget(id)!.options['iconSize'], 'max');
      workspace.document.validate();
      for (final alignment in ['left', 'center', 'spaceEvenly', 'right']) {
        expect(
          workspace.updateWidget(id, options: {'alignment': alignment}),
          true,
        );
      }
      expect(workspace.updateWidget(id, options: {'rows': 13}), false);
      expect(
        workspace.updateWidget(id, options: {'alignment': 'justify'}),
        false,
      );
      expect(
        workspace.updateWidget(id, options: {'iconSize': 'largest'}),
        false,
      );
    },
  );

  test('usage display options support filling without layout details', () {
    final workspace = emptyWorkspace();
    final id = workspace.addWidget('usage')!;
    final defaults = workspace.findWidget(id)!.options;
    expect(defaults['density'], 'fill');
    expect(defaults['alignment'], 'spaceEvenly');
    expect(defaults.containsKey('showDetails'), isFalse);
    expect(
      workspace.updateWidget(
        id,
        options: {'density': 'standard', 'alignment': 'bottom'},
      ),
      true,
    );
    expect(workspace.findWidget(id)!.options['density'], 'standard');
    workspace.document.validate();
    expect(workspace.updateWidget(id, options: {'density': 'expanded'}), false);
    expect(workspace.updateWidget(id, options: {'alignment': 'right'}), false);
    expect(workspace.updateWidget(id, options: {'showDetails': 'yes'}), false);

    final legacy = LayoutDocument.fromJson({
      ...workspace.document.toJson(),
      'pages': [
        {
          ...workspace.document.pages.single.toJson(),
          'widgets': [
            {
              ...workspace.document.pages.single.widgets.single.toJson(),
              'options': {
                ...workspace.document.pages.single.widgets.single.options,
                'showDetails': true,
              },
            },
          ],
        },
      ],
    });
    expect(legacy.pages.single.widgets.single.options['showDetails'], isNull);
    expect(legacy.toJson().toString(), isNot(contains('showDetails')));
  });

  test('mixed random edits always leave the complete draft valid', () {
    final workspace = emptyWorkspace();
    final random = Random(42);
    for (var i = 0; i < 250; i++) {
      final widgets = workspace.activePage.widgets;
      switch (random.nextInt(8)) {
        case 0:
          workspace.addWidget(
            ['usage', 'sessions', 'shortcuts'][random.nextInt(3)],
          );
        case 1:
          if (widgets.isNotEmpty) {
            workspace.setWidgetVisible(
              widgets.first.id,
              !widgets.first.visible,
            );
          }
        case 2:
          if (widgets.isNotEmpty) {
            workspace.setPlacement(
              widgets.first.id,
              LayoutOrientation.wide,
              GridPlacement(
                x: random.nextInt(LayoutOrientation.wide.columns),
                y: random.nextInt(LayoutOrientation.wide.rows),
                w: 16,
                h: 16,
              ),
            );
          }
        case 3:
          workspace.arrangePage(LayoutOrientation.values[random.nextInt(2)]);
        case 4:
          workspace.undo();
        case 5:
          workspace.redo();
        case 6:
          if (widgets.isNotEmpty) workspace.removeWidget(widgets.last.id);
        case 7:
          if (workspace.pages.length < 4) {
            workspace.addPage();
          } else {
            workspace.setActivePage(
              workspace.pages[random.nextInt(workspace.pages.length)].id,
            );
          }
      }
      workspace.document.validate();
    }
  });
}
