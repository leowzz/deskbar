import 'package:desklet/layout_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

LayoutWorkspace crowdedWorkspace({bool chain = false}) => LayoutWorkspace(
  document: LayoutDocument(
    activePageId: 'main',
    pages: [
      LayoutPage(
        id: 'main',
        name: '工作台',
        widgets: [
          for (final spec in [
            ('a', 0, 4),
            ('b', 4, chain ? 8 : 4),
            ('c', 12, 4),
          ])
            LayoutWidget(
              id: spec.$1,
              type: 'usage',
              title: spec.$1,
              binding: {'hostId': 'host', 'source': 'codex.quota'},
              options: {'content': 'quota'},
              placements: {
                for (final orientation in LayoutOrientation.values)
                  orientation: GridPlacement(
                    x: spec.$2,
                    y: 0,
                    w: spec.$3,
                    h: orientation.rows,
                  ),
              },
            ),
        ],
      ),
      LayoutPage(id: 'other', name: '另一页'),
    ],
  ),
)..beginEdit();

void main() {
  const orientation = LayoutOrientation.portrait;
  test(
    'preview preserves document and moves only collisions to nearest free space',
    () {
      final workspace = crowdedWorkspace();
      addTearDown(workspace.dispose);
      final before = workspace.document.toJson();
      final target = workspace
          .findWidget('a')!
          .placementFor(orientation)
          .copyWith(x: 4);
      final preview = workspace.previewPlacement('a', orientation, target)!;
      expect(preview['a'], target);
      expect(preview['b']!.x, 0);
      expect(
        preview['c'],
        workspace.findWidget('c')!.placementFor(orientation),
      );
      expect(workspace.document.toJson(), before);
      expect(workspace.canUndo, false);
      expect(workspace.previewPlacement('a', orientation, target), preview);
    },
  );

  test(
    'full page supports chain displacement and one undo restores all widgets',
    () {
      final workspace = crowdedWorkspace(chain: true);
      addTearDown(workspace.dispose);
      final before = workspace.document.toJson();
      final wide = workspace.activePage.widgets
          .map((w) => w.placementFor(LayoutOrientation.wide))
          .toList();
      final target = workspace
          .findWidget('a')!
          .placementFor(orientation)
          .copyWith(x: 4);
      expect(
        workspace.setPlacement('a', orientation, target, displace: true),
        true,
      );
      expect(workspace.findWidget('b')!.placementFor(orientation).x, 8);
      expect(workspace.findWidget('c')!.placementFor(orientation).x, 0);
      expect(
        workspace.activePage.widgets.map(
          (w) => w.placementFor(LayoutOrientation.wide),
        ),
        wide,
      );
      expect(workspace.pages.last.toJson(), (before['pages'] as List).last);
      final after = workspace.document.toJson();
      workspace.document.validate();
      expect(workspace.undo(), true);
      expect(workspace.document.toJson(), before);
      expect(workspace.canUndo, false);
      expect(workspace.redo(), true);
      expect(workspace.document.toJson(), after);
      workspace.cancelEdit();
      expect(workspace.document.toJson(), before);
    },
  );

  test(
    'impossible placement and oversized resize preserve all state and history',
    () {
      final workspace = crowdedWorkspace(chain: true);
      addTearDown(workspace.dispose);
      final before = workspace.document.toJson();
      final old = workspace.findWidget('a')!.placementFor(orientation);
      for (final target in [
        old.copyWith(x: 2),
        old.copyWith(w: 8),
        old.copyWith(x: -1),
      ]) {
        expect(workspace.previewPlacement('a', orientation, target), isNull);
        expect(
          workspace.setPlacement('a', orientation, target, displace: true),
          false,
        );
        expect(workspace.document.toJson(), before);
        expect(workspace.canUndo, false);
      }
    },
  );

  test('hidden widgets do not reserve space or get moved by displacement', () {
    final workspace = crowdedWorkspace();
    addTearDown(workspace.dispose);
    workspace.setWidgetVisible('b', false);
    expect(
      workspace.setPlacement(
        'b',
        orientation,
        workspace.findWidget('b')!.placementFor(orientation).copyWith(w: 2),
        displace: true,
      ),
      true,
    );
    final hidden = workspace.findWidget('b')!.toJson();
    final target = workspace
        .findWidget('a')!
        .placementFor(orientation)
        .copyWith(x: 4);
    expect(
      workspace.setPlacement('a', orientation, target, displace: true),
      true,
    );
    expect(workspace.findWidget('b')!.toJson(), hidden);
    workspace.document.validate();
  });
}
