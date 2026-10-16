import 'dart:convert';
import 'dart:io';

import 'package:desklet/layout_repository.dart';
import 'package:desklet/layout_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late LayoutRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('desklet-layout-test-');
    repository = LayoutRepository(directory: directory);
  });
  tearDown(() async => directory.delete(recursive: true));
  File primary() => File('${directory.path}/layout.json');
  File backup() => File('${directory.path}/layout.json.bak');

  test(
    'fresh install defaults and committed draft survives process restart',
    () async {
      final loaded = await repository.load();
      expect(loaded.warning, isNull);
      final workspace = LayoutWorkspace(document: loaded.document)..beginEdit();
      workspace.addPage(name: '专注');
      workspace.addWidget(
        'usage',
        binding: {'hostId': 'host-a', 'source': 'api'},
        options: {'content': 'api'},
      );
      await repository.save(workspace.document);
      workspace.commitEdit();
      final restarted = await LayoutRepository(directory: directory).load();
      expect(restarted.document.toJson(), workspace.committed.toJson());
      expect(restarted.document.activePage.name, '专注');
      expect(
        directory.listSync().where((file) => file.path.contains('.tmp.')),
        isEmpty,
      );
    },
  );

  test(
    'previous valid save is recovered while damaged primary is preserved',
    () async {
      final initial = LayoutDocument.initial();
      await repository.save(initial);
      final workspace = LayoutWorkspace(document: initial)..beginEdit();
      workspace.renamePage('page-main', '新名称');
      await repository.save(workspace.document);
      expect(
        LayoutDocument.fromJson(
          jsonDecode(await backup().readAsString()),
        ).toJson(),
        initial.toJson(),
      );
      await primary().writeAsString('{truncated');
      final restored = await LayoutRepository(directory: directory).load();
      expect(restored.recovered, true);
      expect(restored.document.toJson(), initial.toJson());
      expect(await File(restored.backupPath!).readAsString(), '{truncated');
      final again = await LayoutRepository(directory: directory).load();
      expect(again.warning, isNull);
      expect(again.document.toJson(), initial.toJson());
    },
  );

  test('missing primary recovers backup', () async {
    await backup().writeAsString(jsonEncode(LayoutDocument.initial().toJson()));
    final loaded = await repository.load();
    expect(loaded.recovered, true);
    expect(await primary().exists(), true);
  });

  test('invalid UTF-8 recovers backup and preserves original bytes', () async {
    await backup().writeAsString(jsonEncode(LayoutDocument.initial().toJson()));
    const damagedBytes = [0xff, 0xfe, 0x7b, 0x00];
    await primary().writeAsBytes(damagedBytes);
    final loaded = await repository.load();
    expect(loaded.recovered, true);
    expect(await File(loaded.backupPath!).readAsBytes(), damagedBytes);
    expect((await repository.load()).warning, isNull);
  });

  test(
    'both corrupt files remain available and explicit save retains good backup policy',
    () async {
      await primary().writeAsString('broken main');
      await backup().writeAsString('broken backup');
      final loaded = await repository.load();
      expect(loaded.warning, isNotNull);
      expect(loaded.recovered, false);
      expect(await primary().readAsString(), 'broken main');
      expect(await backup().readAsString(), 'broken backup');
      await repository.save(loaded.document);
      expect(await backup().readAsString(), 'broken backup');
      expect((await repository.load()).warning, isNull);
      expect(
        directory.listSync().where((file) => file.path.contains('.damaged.')),
        isNotEmpty,
      );
    },
  );

  test(
    'failed backup write leaves primary intact and temporary files cleaned',
    () async {
      await repository.save(LayoutDocument.initial());
      final previous = await primary().readAsString();
      await Directory(backup().path).create();
      final workspace = LayoutWorkspace()..beginEdit();
      workspace.renamePage('page-main', '不能保存');
      await expectLater(
        repository.save(workspace.document),
        throwsA(isA<FileSystemException>()),
      );
      expect(await primary().readAsString(), previous);
      expect(workspace.editing, true);
      expect(
        directory.listSync().where((file) => file.path.contains('.tmp.')),
        isEmpty,
      );
    },
  );

  test(
    'queued writes preserve ordering after an earlier validation failure',
    () async {
      final invalid = LayoutDocument(activePageId: 'missing', pages: []);
      final workspace = LayoutWorkspace()..beginEdit();
      workspace.renamePage('page-main', '最后一次');
      final failure = repository.save(invalid);
      final first = repository.save(LayoutDocument.initial());
      final last = repository.save(workspace.document);
      await expectLater(failure, throwsFormatException);
      await Future.wait([first, last]);
      expect((await repository.load()).document.activePage.name, '最后一次');
    },
  );

  test(
    'legacy canvas migration backs up original and preserves IDs/options/unknown fields',
    () async {
      final legacy = jsonEncode({
        'schemaVersion': 1,
        'name': '旧画布',
        'orientation': 'wide',
        'widgets': [
          {
            'id': 'legacy-id',
            'type': 'unknown-provider',
            'visible': true,
            'rect': {'x': 0, 'y': 0, 'w': 6, 'h': 6},
            'binding': {'hostId': 'stable-host', 'source': 'codex'},
            'options': {
              'itemWidth': 325,
              'unrecognized': {'keep': true},
            },
            'providerData': ['retained'],
          },
        ],
      });
      await primary().writeAsString(legacy);
      final migrated = await repository.load();
      expect(migrated.migrated, true);
      expect(migrated.document.pages, hasLength(1));
      final widget = migrated.document.activePage.widgets.single;
      expect(widget.id, 'legacy-id');
      expect(widget.options['itemWidth'], 325);
      expect(widget.binding['hostId'], 'stable-host');
      expect(widget.toJson()['providerData'], ['retained']);
      expect(
        widget.placementFor(LayoutOrientation.wide),
        const GridPlacement(x: 0, y: 0, w: 6, h: 6),
      );
      expect(await File(migrated.backupPath!).readAsString(), legacy);
      expect(
        (jsonDecode(await primary().readAsString()) as Map)['schemaVersion'],
        2,
      );
      expect(
        (await LayoutRepository(directory: directory).load()).migrated,
        false,
      );
    },
  );

  test(
    'legacy two profiles preserve user placement in both directions',
    () async {
      Map<String, dynamic> old(String id, Map<String, int> rect) => {
        'id': id,
        'type': 'sessions',
        'rect': rect,
        'options': {'itemHeight': 130},
      };
      final wide = old('session', {'x': 2, 'y': 3, 'w': 8, 'h': 6});
      final portrait = old('session', {'x': 1, 'y': 2, 'w': 3, 'h': 20});
      await primary().writeAsString(
        jsonEncode({
          'orientation': 'portrait',
          'widgets': [portrait],
          'profiles': {
            'wide': [wide],
            'portrait': [portrait],
          },
        }),
      );
      final migrated = await repository.load();
      final widget = migrated.document.activePage.widgets.single;
      expect(
        widget.placementFor(LayoutOrientation.wide).toJson(),
        wide['rect'],
      );
      expect(
        widget.placementFor(LayoutOrientation.portrait).toJson(),
        portrait['rect'],
      );
    },
  );

  test(
    'invalid migration retains every original byte instead of dropping instances',
    () async {
      final legacy = jsonEncode({
        'widgets': [
          for (final id in ['a', 'b'])
            {
              'id': id,
              'type': 'sessions',
              'rect': {'x': 0, 'y': 0, 'w': 12, 'h': 12},
              'options': {},
            },
        ],
      });
      await primary().writeAsString(legacy);
      final loaded = await repository.load();
      expect(loaded.migrated, false);
      expect(loaded.warning, isNotNull);
      expect(await primary().readAsString(), legacy);
      expect(await File(loaded.backupPath!).readAsString(), legacy);
    },
  );

  test('future schema is preserved and cannot be overwritten', () async {
    final future = jsonEncode({'schemaVersion': 99, 'future': 'valuable'});
    await primary().writeAsString(future);
    final loaded = await repository.load();
    expect(loaded.readOnly, true);
    await expectLater(repository.save(loaded.document), throwsFormatException);
    await expectLater(
      LayoutRepository(directory: directory).save(loaded.document),
      throwsFormatException,
    );
    expect(await primary().readAsString(), future);
  });
}
