import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'layout_workspace.dart';

class LayoutLoadResult {
  const LayoutLoadResult({
    required this.document,
    this.warning,
    this.recovered = false,
    this.migrated = false,
    this.readOnly = false,
    this.backupPath,
  });
  final LayoutDocument document;
  final String? warning;
  final bool recovered;
  final bool migrated;
  final bool readOnly;
  final String? backupPath;
}

/// Local non-sensitive layout storage. Atomic replacement keeps the previous
/// valid file as a recovery copy; edit drafts and runtime state never reach it.
class LayoutRepository {
  LayoutRepository({this._directory});
  static const _channel = MethodChannel('app.desklet/layout');
  Directory? _directory;
  Future<void> _pending = Future.value();
  int _sequence = 0;
  bool _futureVersion = false;

  Future<Directory> _root() async {
    if (_directory == null) {
      final path = await _channel.invokeMethod<String>('directory');
      if (path == null || path.isEmpty) {
        throw const FileSystemException('无法读取本机保存目录');
      }
      _directory = Directory('$path/workbench');
    }
    await _directory!.create(recursive: true);
    return _directory!;
  }

  Future<T> _exclusive<T>(Future<T> Function() work) {
    final result = _pending.then((_) => work());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<LayoutLoadResult> load() => _exclusive(() async {
    final root = await _root();
    final file = File('${root.path}/layout.json');
    final backup = File('${root.path}/layout.json.bak');
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      try {
        final content = utf8.decode(bytes);
        final decoded = _decode(content);
        _futureVersion = false;
        if (!decoded.migrated) {
          return LayoutLoadResult(document: decoded.document);
        }
        final legacy = await _preserve(root, content, 'legacy');
        await _atomicWrite(backup, content);
        await _atomicWrite(file, jsonEncode(decoded.document.toJson()));
        return LayoutLoadResult(
          document: decoded.document,
          migrated: true,
          warning: '已升级布局，原配置已备份',
          backupPath: legacy.path,
        );
      } on _FutureLayoutVersion {
        _futureVersion = true;
        return LayoutLoadResult(
          document: LayoutDocument.initial(),
          readOnly: true,
          warning: '布局来自较新版本，请升级工作台后再编辑；原配置已保留',
        );
      } on FormatException {
        final damaged = await _preserveBytes(root, bytes, 'damaged');
        if (await backup.exists()) {
          try {
            final restored = _decode(await backup.readAsString());
            await _atomicWrite(file, jsonEncode(restored.document.toJson()));
            _futureVersion = false;
            return LayoutLoadResult(
              document: restored.document,
              recovered: true,
              migrated: restored.migrated,
              warning: '布局文件损坏，已恢复上一次保存；损坏文件已保留',
              backupPath: damaged.path,
            );
          } on FormatException {
            // Preserve both files. A later explicit save may replace the main
            // file, but cannot erase the evidence needed for manual recovery.
          }
        }
        return LayoutLoadResult(
          document: LayoutDocument.initial(),
          warning: '未能读取布局，已显示初始页面；原配置和恢复文件均已保留',
          backupPath: damaged.path,
        );
      }
    }
    // A deleted primary can still be recovered after an interrupted upgrade.
    if (await backup.exists()) {
      try {
        final restored = _decode(await backup.readAsString());
        await _atomicWrite(file, jsonEncode(restored.document.toJson()));
        return LayoutLoadResult(
          document: restored.document,
          recovered: true,
          migrated: restored.migrated,
          warning: '已从本机备份恢复布局',
          backupPath: backup.path,
        );
      } on FormatException {
        return LayoutLoadResult(
          document: LayoutDocument.initial(),
          warning: '备份布局无法读取，原文件已保留',
          backupPath: backup.path,
        );
      }
    }
    return LayoutLoadResult(document: LayoutDocument.initial());
  });

  Future<void> save(LayoutDocument document) => _exclusive(() async {
    document.validate();
    if (_futureVersion) throw const FormatException('请升级工作台后再保存布局');
    final root = await _root();
    final file = File('${root.path}/layout.json');
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      try {
        final previous = utf8.decode(bytes);
        final decoded = _decode(previous);
        if (decoded.migrated) await _preserve(root, previous, 'legacy');
        await _atomicWrite(File('${root.path}/layout.json.bak'), previous);
      } on _FutureLayoutVersion {
        _futureVersion = true;
        throw const FormatException('布局来自较新版本，请升级后再保存');
      } on FormatException {
        await _preserveBytes(root, bytes, 'damaged');
      }
    }
    await _atomicWrite(file, jsonEncode(document.toJson()));
  });

  Future<File> _preserve(Directory root, String content, String reason) async {
    return _preserveBytes(root, utf8.encode(content), reason);
  }

  Future<File> _preserveBytes(
    Directory root,
    List<int> bytes,
    String reason,
  ) async {
    final file = File(
      '${root.path}/layout.$reason.${DateTime.now().microsecondsSinceEpoch}.${_sequence++}.json',
    );
    await _atomicWriteBytes(file, bytes);
    return file;
  }

  Future<void> _atomicWrite(File target, String contents) async {
    await _atomicWriteBytes(target, utf8.encode(contents));
  }

  Future<void> _atomicWriteBytes(File target, List<int> bytes) async {
    final temporary = File(
      '${target.path}.tmp.${DateTime.now().microsecondsSinceEpoch}.${_sequence++}',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class _DecodedLayout {
  const _DecodedLayout(this.document, {this.migrated = false});
  final LayoutDocument document;
  final bool migrated;
}

class _FutureLayoutVersion extends FormatException {
  const _FutureLayoutVersion() : super('布局来自较新版本');
}

_DecodedLayout _decode(String content) {
  final value = jsonDecode(content);
  if (value is! Map<String, dynamic>) throw const FormatException('布局必须是对象');
  final version = value['schemaVersion'];
  if (version is int && version > LayoutDocument.currentSchemaVersion) {
    throw const _FutureLayoutVersion();
  }
  if (version == LayoutDocument.currentSchemaVersion) {
    return _DecodedLayout(LayoutDocument.fromJson(value));
  }
  if (version == 2) {
    // Validate in the old coordinate bounds before scaling. Keep all unknown
    // fields and both orientation profiles intact.
    final pages = value['pages'];
    if (pages is! List) throw const FormatException('页面列表无效');
    for (final page in pages) {
      if (page is! Map<String, dynamic> || page['widgets'] is! List) {
        throw const FormatException('页面组件无效');
      }
      for (final widget in page['widgets'] as List) {
        if (widget is! Map<String, dynamic> || widget['placements'] is! Map) {
          throw const FormatException('组件位置无效');
        }
        final placements = widget['placements'] as Map;
        for (final orientation in LayoutOrientation.values) {
          placements[orientation.name] = _upgradeRect(
            placements[orientation.name],
            orientation,
          ).toJson();
        }
      }
    }
    value['schemaVersion'] = LayoutDocument.currentSchemaVersion;
    return _DecodedLayout(LayoutDocument.fromJson(value), migrated: true);
  }
  if (version != null && version != 1) throw const FormatException('布局版本无效');
  return _DecodedLayout(_migrateCanvas(value), migrated: true);
}

/// Accepts the original single-canvas shape and the prototype's two profiles.
/// Existing coordinates are preserved; only a missing orientation is packed.
LayoutDocument _migrateCanvas(Map<String, dynamic> value) {
  final rawWidgets = value['widgets'];
  if (rawWidgets is! List) throw const FormatException('找不到旧画布组件');
  final profiles = value['profiles'];
  final profileMap = profiles is Map<String, dynamic>
      ? profiles
      : <String, dynamic>{};
  final current = value['orientation'] == 'portrait'
      ? LayoutOrientation.portrait
      : LayoutOrientation.wide;
  final ids = <String>{};
  final widgets = <LayoutWidget>[];
  final missing = <String, Set<LayoutOrientation>>{};
  for (var index = 0; index < rawWidgets.length; index++) {
    final raw = rawWidgets[index];
    if (raw is! Map<String, dynamic>) throw const FormatException('旧组件无效');
    final id = raw['id'] is String && (raw['id'] as String).isNotEmpty
        ? raw['id'] as String
        : 'migrated-widget-$index';
    if (!ids.add(id)) throw const FormatException('旧组件 ID 重复');
    final placements = <LayoutOrientation, GridPlacement>{};
    final oldPlacements = raw['placements'];
    for (final orientation in LayoutOrientation.values) {
      dynamic rectangle;
      if (oldPlacements is Map) rectangle = oldPlacements[orientation.name];
      final profile = profileMap[orientation.name];
      if (rectangle == null && profile is List) {
        for (final item in profile) {
          if (item is Map && item['id'] == id) {
            rectangle = item['rect'];
            break;
          }
        }
      }
      if (rectangle == null && orientation == current) rectangle = raw['rect'];
      if (rectangle is Map<String, dynamic>) {
        placements[orientation] = _upgradeRect(rectangle, orientation);
      } else {
        (missing[id] ??= {}).add(orientation);
        final type = raw['type'];
        if (type is! String) throw const FormatException('旧组件类型无效');
        placements[orientation] = LayoutWorkspace.defaultPlacement(
          type,
          orientation,
        );
      }
    }
    final migrated = <String, dynamic>{
      ...raw,
      'id': id,
      'placements': {
        for (final entry in placements.entries)
          entry.key.name: entry.value.toJson(),
      },
    }..remove('rect');
    widgets.add(LayoutWidget.fromJson(migrated));
  }
  // Pack missing orientations around the explicit rectangles, including unknown
  // components. No instance is dropped if migration cannot fit all widgets.
  for (final orientation in LayoutOrientation.values) {
    final occupied = <GridPlacement>[
      for (final widget in widgets)
        if (widget.visible &&
            !(missing[widget.id]?.contains(orientation) ?? false))
          widget.placementFor(orientation),
    ];
    for (var index = 0; index < widgets.length; index++) {
      final widget = widgets[index];
      if (!(missing[widget.id]?.contains(orientation) ?? false)) continue;
      final old = widget.placementFor(current);
      final width = min(
        orientation.columns,
        max(1, (old.w * orientation.columns / current.columns).ceil()),
      );
      final height = min(
        orientation.rows,
        max(1, (old.h * orientation.rows / current.rows).ceil()),
      );
      GridPlacement? found;
      for (var y = 0; y <= orientation.rows - height && found == null; y++) {
        for (var x = 0; x <= orientation.columns - width; x++) {
          final rect = GridPlacement(x: x, y: y, w: width, h: height);
          if (!widget.visible ||
              occupied.every((other) => !rect.overlaps(other))) {
            found = rect;
            break;
          }
        }
      }
      if (found == null) throw const FormatException('旧组件无法放入另一方向的画布');
      if (widget.visible) occupied.add(found);
      widgets[index] = widget.copyWith(
        placements: {...widget.placements, orientation: found},
      );
    }
  }
  final result = LayoutDocument(
    activePageId: 'page-migrated',
    pages: [
      LayoutPage(
        id: 'page-migrated',
        name:
            value['name'] is String &&
                (value['name'] as String).trim().isNotEmpty
            ? value['name'] as String
            : '我的工作台',
        widgets: widgets,
      ),
    ],
  );
  result.validate();
  return result;
}

GridPlacement _upgradeRect(dynamic value, LayoutOrientation orientation) {
  if (value is! Map<String, dynamic>) throw const FormatException('组件位置无效');
  final rect = GridPlacement.fromJson(value).scaled(4);
  if (!rect.fits(orientation)) throw const FormatException('旧组件超出画布范围');
  return rect;
}
