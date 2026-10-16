import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

enum LayoutOrientation { wide, portrait }

extension LayoutOrientationGrid on LayoutOrientation {
  int get columns => this == LayoutOrientation.wide ? 12 : 4;
  int get rows => this == LayoutOrientation.wide ? 12 : 24;
}

/// Integer grid coordinates, independent of the current viewport and safe area.
@immutable
class GridPlacement {
  const GridPlacement({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final int x;
  final int y;
  final int w;
  final int h;

  bool fits(LayoutOrientation orientation) =>
      x >= 0 &&
      y >= 0 &&
      w > 0 &&
      h > 0 &&
      x + w <= orientation.columns &&
      y + h <= orientation.rows;

  bool overlaps(GridPlacement other) =>
      x < other.x + other.w &&
      x + w > other.x &&
      y < other.y + other.h &&
      y + h > other.y;

  GridPlacement copyWith({int? x, int? y, int? w, int? h}) => GridPlacement(
    x: x ?? this.x,
    y: y ?? this.y,
    w: w ?? this.w,
    h: h ?? this.h,
  );

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};

  factory GridPlacement.fromJson(Map<String, dynamic> json) => GridPlacement(
    x: _integer(json['x']),
    y: _integer(json['y']),
    w: _integer(json['w']),
    h: _integer(json['h']),
  );

  @override
  bool operator ==(Object other) =>
      other is GridPlacement &&
      x == other.x &&
      y == other.y &&
      w == other.w &&
      h == other.h;
  @override
  int get hashCode => Object.hash(x, y, w, h);
}

@immutable
class LayoutWidget {
  LayoutWidget({
    required this.id,
    required this.type,
    this.visible = true,
    this.title = '',
    Map<String, dynamic> binding = const {},
    Map<String, dynamic> options = const {},
    required Map<LayoutOrientation, GridPlacement> placements,
    Map<String, dynamic> extra = const {},
  }) : binding = _frozenMap(binding),
       options = _frozenMap(options),
       placements = Map.unmodifiable(placements),
       extra = _frozenMap(extra);

  final String id;
  final String type;
  final bool visible;
  final String title;
  final Map<String, dynamic> binding;
  final Map<String, dynamic> options;
  final Map<LayoutOrientation, GridPlacement> placements;
  final Map<String, dynamic> extra;
  bool get isKnown => const {'sessions', 'usage', 'shortcuts'}.contains(type);

  GridPlacement placementFor(LayoutOrientation orientation) =>
      placements[orientation]!;

  LayoutWidget copyWith({
    String? title,
    bool? visible,
    Map<String, dynamic>? binding,
    Map<String, dynamic>? options,
    Map<LayoutOrientation, GridPlacement>? placements,
  }) => LayoutWidget(
    id: id,
    type: type,
    title: title ?? this.title,
    visible: visible ?? this.visible,
    binding: binding ?? this.binding,
    options: options ?? this.options,
    placements: placements ?? this.placements,
    extra: extra,
  );

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'type': type,
    'title': title,
    'visible': visible,
    'binding': binding,
    'options': options,
    'placements': {
      for (final item in placements.entries) item.key.name: item.value.toJson(),
    },
  };

  factory LayoutWidget.fromJson(Map<String, dynamic> json) {
    final placements = _map(json['placements']);
    if (json['visible'] != null && json['visible'] is! bool) {
      throw const FormatException('组件可见性无效');
    }
    final binding = _map(json['binding'] ?? <String, dynamic>{});
    _validateBinding(binding);
    return LayoutWidget(
      id: _nonempty(json['id']),
      type: _nonempty(json['type']),
      title: json['title'] == null ? '' : _string(json['title']),
      visible: json['visible'] as bool? ?? true,
      binding: binding,
      options: _map(json['options'] ?? <String, dynamic>{}),
      placements: {
        for (final orientation in LayoutOrientation.values)
          orientation: GridPlacement.fromJson(
            _map(placements[orientation.name]),
          ),
      },
      extra: _without(json, const {
        'id',
        'type',
        'title',
        'visible',
        'binding',
        'options',
        'placements',
      }),
    );
  }
}

@immutable
class LayoutPage {
  LayoutPage({
    required this.id,
    required this.name,
    List<LayoutWidget> widgets = const [],
    Map<String, dynamic> extra = const {},
  }) : widgets = List.unmodifiable(widgets),
       extra = _frozenMap(extra);
  final String id;
  final String name;
  final List<LayoutWidget> widgets;
  final Map<String, dynamic> extra;
  LayoutPage copyWith({String? name, List<LayoutWidget>? widgets}) =>
      LayoutPage(
        id: id,
        name: name ?? this.name,
        widgets: widgets ?? this.widgets,
        extra: extra,
      );
  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'name': name,
    'widgets': widgets.map((widget) => widget.toJson()).toList(),
  };
  factory LayoutPage.fromJson(Map<String, dynamic> json) => LayoutPage(
    id: _nonempty(json['id']),
    name: _nonempty(json['name']),
    widgets: _list(
      json['widgets'],
    ).map((widget) => LayoutWidget.fromJson(_map(widget))).toList(),
    extra: _without(json, const {'id', 'name', 'widgets'}),
  );
}

@immutable
class LayoutDocument {
  LayoutDocument({
    required this.activePageId,
    required List<LayoutPage> pages,
    Map<String, dynamic> extra = const {},
  }) : pages = List.unmodifiable(pages),
       extra = _frozenMap(extra);
  static const currentSchemaVersion = 2;
  int get schemaVersion => currentSchemaVersion;
  final String activePageId;
  final List<LayoutPage> pages;
  final Map<String, dynamic> extra;
  LayoutPage get activePage =>
      pages.firstWhere((page) => page.id == activePageId);
  LayoutDocument copyWith({String? activePageId, List<LayoutPage>? pages}) =>
      LayoutDocument(
        activePageId: activePageId ?? this.activePageId,
        pages: pages ?? this.pages,
        extra: extra,
      );
  Map<String, dynamic> toJson() => {
    ...extra,
    'schemaVersion': schemaVersion,
    'activePageId': activePageId,
    'pages': pages.map((page) => page.toJson()).toList(),
  };

  factory LayoutDocument.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != currentSchemaVersion) {
      throw const FormatException('不支持的布局版本');
    }
    final result = LayoutDocument(
      activePageId: _nonempty(json['activePageId']),
      pages: _list(
        json['pages'],
      ).map((page) => LayoutPage.fromJson(_map(page))).toList(),
      extra: _without(json, const {'schemaVersion', 'activePageId', 'pages'}),
    );
    result.validate();
    return result;
  }

  void validate() {
    if (pages.isEmpty || !pages.any((page) => page.id == activePageId)) {
      throw const FormatException('布局必须包含当前页面');
    }
    final ids = <String>{};
    for (final page in pages) {
      if (page.id.trim().isEmpty ||
          page.name.trim().isEmpty ||
          !ids.add(page.id)) {
        throw const FormatException('页面名称或 ID 无效');
      }
      for (final widget in page.widgets) {
        if (widget.id.trim().isEmpty ||
            widget.type.trim().isEmpty ||
            !ids.add(widget.id)) {
          throw const FormatException('组件 ID 无效或重复');
        }
        _validateBinding(widget.binding);
        _validateOptions(widget.type, widget.options);
        for (final orientation in LayoutOrientation.values) {
          final rect = widget.placements[orientation];
          if (rect == null || !rect.fits(orientation)) {
            throw const FormatException('组件超出页面范围');
          }
          if (widget.visible &&
              page.widgets.any(
                (other) =>
                    other.id != widget.id &&
                    other.visible &&
                    other.placements[orientation] != null &&
                    rect.overlaps(other.placements[orientation]!),
              )) {
            throw const FormatException('组件相互重叠');
          }
        }
      }
    }
  }

  factory LayoutDocument.initial() {
    LayoutWidget widget(
      String id,
      String type,
      String title,
      GridPlacement wide,
      GridPlacement portrait,
    ) => LayoutWidget(
      id: id,
      type: type,
      title: title,
      binding: {'source': 'codex'},
      options: LayoutWorkspace.defaultOptions(type),
      placements: {
        LayoutOrientation.wide: wide,
        LayoutOrientation.portrait: portrait,
      },
    );
    return LayoutDocument(
      activePageId: 'page-main',
      pages: [
        LayoutPage(
          id: 'page-main',
          name: '总览',
          widgets: [
            widget(
              'main-sessions',
              'sessions',
              '近期会话',
              const GridPlacement(x: 0, y: 0, w: 8, h: 8),
              const GridPlacement(x: 0, y: 6, w: 4, h: 12),
            ),
            widget(
              'main-usage',
              'usage',
              'Codex 额度',
              const GridPlacement(x: 8, y: 0, w: 4, h: 8),
              const GridPlacement(x: 0, y: 0, w: 4, h: 6),
            ),
            widget(
              'main-shortcuts',
              'shortcuts',
              '快捷入口',
              const GridPlacement(x: 0, y: 8, w: 12, h: 4),
              const GridPlacement(x: 0, y: 18, w: 4, h: 6),
            ),
          ],
        ),
        LayoutPage(
          id: 'page-tasks',
          name: '任务',
          widgets: [
            widget(
              'tasks-sessions',
              'sessions',
              '近期会话',
              const GridPlacement(x: 0, y: 0, w: 12, h: 12),
              const GridPlacement(x: 0, y: 0, w: 4, h: 24),
            ),
          ],
        ),
        LayoutPage(
          id: 'page-apps',
          name: '应用',
          widgets: [
            widget(
              'apps-shortcuts',
              'shortcuts',
              '快捷入口',
              const GridPlacement(x: 0, y: 0, w: 12, h: 12),
              const GridPlacement(x: 0, y: 0, w: 4, h: 24),
            ),
          ],
        ),
      ],
    );
  }
}

/// The committed document and the entire multi-page edit draft are separate.
/// Selection, focus and history deliberately never enter [LayoutDocument].
class LayoutWorkspace extends ChangeNotifier {
  LayoutWorkspace({LayoutDocument? document, String Function()? idFactory})
    : _committed = document ?? LayoutDocument.initial(),
      _idFactory = idFactory ?? _randomId {
    _committed.validate();
  }
  LayoutDocument _committed;
  LayoutDocument? _draft;
  final String Function() _idFactory;
  final List<LayoutDocument> _history = [];
  final List<LayoutDocument> _future = [];
  String? selectedWidgetId;
  String? focusedWidgetId;
  String? error;

  LayoutDocument get document => _draft ?? _committed;
  LayoutDocument get committed => _committed;
  List<LayoutPage> get pages => document.pages;
  LayoutPage get activePage => document.activePage;
  bool get editing => _draft != null;
  bool get canUndo => editing && _history.isNotEmpty;
  bool get canRedo => editing && _future.isNotEmpty;
  LayoutWidget? get selectedWidget => findWidget(selectedWidgetId);
  LayoutWidget? findWidget(String? id) {
    for (final page in pages) {
      for (final widget in page.widgets) {
        if (widget.id == id) return widget;
      }
    }
    return null;
  }

  void replaceDocument(LayoutDocument document) {
    document.validate();
    _committed = document;
    _draft = null;
    _clearTransient();
    notifyListeners();
  }

  void beginEdit() {
    if (editing) return;
    _draft = _committed;
    _clearTransient();
    notifyListeners();
  }

  void cancelEdit() {
    if (!editing) return;
    _draft = null;
    _clearTransient();
    notifyListeners();
  }

  /// Persist [document] before calling this method; a save error keeps the draft.
  LayoutDocument commitEdit() {
    document.validate();
    _committed = document;
    _draft = null;
    _clearTransient();
    notifyListeners();
    return _committed;
  }

  bool setActivePage(String id) {
    if (!pages.any((page) => page.id == id)) return _fail('找不到页面');
    if (document.activePageId == id) return true;
    final next = document.copyWith(activePageId: id);
    if (editing) {
      _draft = next;
    } else {
      _committed = next;
    }
    selectedWidgetId = null;
    focusedWidgetId = null;
    error = null;
    notifyListeners();
    return true;
  }

  void selectWidget(String? id) {
    if (id != null && !activePage.widgets.any((widget) => widget.id == id)) {
      return;
    }
    selectedWidgetId = id;
    notifyListeners();
  }

  void toggleFocus(String id) {
    final widget = findWidget(id);
    if (widget == null || !widget.visible) return;
    focusedWidgetId = focusedWidgetId == id ? null : id;
    notifyListeners();
  }

  void clearFocus() {
    focusedWidgetId = null;
    notifyListeners();
  }

  String? addPage({String name = '新页面'}) {
    if (!_requireEditing()) return null;
    if (name.trim().isEmpty) {
      _fail('请输入页面名称');
      return null;
    }
    final id = _newId('page');
    _apply(
      document.copyWith(
        activePageId: id,
        pages: [
          ...pages,
          LayoutPage(id: id, name: name.trim()),
        ],
      ),
    );
    return id;
  }

  bool renamePage(String id, String name) {
    if (!_requireEditing()) return false;
    if (name.trim().isEmpty) return _fail('请输入页面名称');
    if (!pages.any((page) => page.id == id)) return _fail('找不到页面');
    return _apply(
      document.copyWith(
        pages: [
          for (final page in pages)
            if (page.id == id) page.copyWith(name: name.trim()) else page,
        ],
      ),
    );
  }

  bool movePage(String id, int index) {
    if (!_requireEditing()) return false;
    if (index < 0 || index >= pages.length) return _fail('页面顺序无效');
    final source = pages.indexWhere((page) => page.id == id);
    if (source < 0) return _fail('找不到页面');
    final next = [...pages];
    next.insert(index, next.removeAt(source));
    return _apply(document.copyWith(pages: next));
  }

  bool deletePage(String id) {
    if (!_requireEditing()) return false;
    if (pages.length <= 1) return _fail('至少保留一个页面');
    final index = pages.indexWhere((page) => page.id == id);
    if (index < 0) return _fail('找不到页面');
    final next = [...pages]..removeAt(index);
    return _apply(
      document.copyWith(
        pages: next,
        activePageId: document.activePageId == id
            ? next[min(index, next.length - 1)].id
            : null,
      ),
    );
  }

  String? addWidget(
    String type, {
    String? pageId,
    String title = '',
    Map<String, dynamic> binding = const {},
    Map<String, dynamic>? options,
  }) {
    if (!_requireEditing()) return null;
    final index = pages.indexWhere(
      (page) => page.id == (pageId ?? activePage.id),
    );
    if (index < 0 || type.trim().isEmpty) {
      _fail('页面或组件类型无效');
      return null;
    }
    try {
      _validateBinding(binding);
      _validateOptions(type, {...defaultOptions(type), ...?options});
    } on FormatException catch (e) {
      _fail(e.message);
      return null;
    }
    final page = pages[index];
    final placements = <LayoutOrientation, GridPlacement>{};
    for (final orientation in LayoutOrientation.values) {
      final size = defaultPlacement(type, orientation);
      final rect = _findSpace(page.widgets, orientation, size.w, size.h);
      if (rect == null) {
        _fail('横屏或竖屏空间不足，请新建页面或先整理');
        return null;
      }
      placements[orientation] = rect;
    }
    final id = _newId('widget');
    final widget = LayoutWidget(
      id: id,
      type: type,
      title: title,
      binding: binding,
      options: {...defaultOptions(type), ...?options},
      placements: placements,
    );
    final next = [...pages];
    next[index] = page.copyWith(widgets: [...page.widgets, widget]);
    _apply(document.copyWith(pages: next));
    selectedWidgetId = id;
    notifyListeners();
    return id;
  }

  bool removeWidget(String id) {
    if (!_requireEditing()) return false;
    if (findWidget(id) == null) return _fail('找不到组件');
    return _apply(
      document.copyWith(
        pages: [
          for (final page in pages)
            page.copyWith(
              widgets: page.widgets.where((widget) => widget.id != id).toList(),
            ),
        ],
      ),
    );
  }

  bool updateWidget(
    String id, {
    String? title,
    Map<String, dynamic>? binding,
    Map<String, dynamic>? options,
  }) {
    if (!_requireEditing()) return false;
    final widget = findWidget(id);
    if (widget == null) return _fail('找不到组件');
    if (binding != null) {
      try {
        _validateBinding(binding);
      } on FormatException catch (e) {
        return _fail(e.message);
      }
    }
    if (options != null) {
      try {
        _validateOptions(widget.type, {...widget.options, ...options});
      } on FormatException catch (e) {
        return _fail(e.message);
      }
    }
    return _replaceWidget(
      widget.copyWith(
        title: title,
        binding: binding,
        options: options == null ? null : {...widget.options, ...options},
      ),
    );
  }

  bool setWidgetVisible(String id, bool visible) {
    if (!_requireEditing()) return false;
    final widget = findWidget(id);
    if (widget == null) return _fail('找不到组件');
    final page = pages.firstWhere(
      (page) => page.widgets.any((item) => item.id == id),
    );
    if (visible &&
        LayoutOrientation.values.any(
          (orientation) =>
              !_fits(page, id, orientation, widget.placementFor(orientation)),
        )) {
      return _fail('原位置已有组件，请先整理或移动占用的组件');
    }
    return _replaceWidget(widget.copyWith(visible: visible));
  }

  bool setPlacement(
    String id,
    LayoutOrientation orientation,
    GridPlacement placement,
  ) {
    if (!_requireEditing()) return false;
    final widget = findWidget(id);
    if (widget == null) return _fail('找不到组件');
    final page = pages.firstWhere(
      (page) => page.widgets.any((item) => item.id == id),
    );
    if (!placement.fits(orientation) ||
        (widget.visible && !_fits(page, id, orientation, placement))) {
      return _fail('组件不能重叠或超出页面');
    }
    return _replaceWidget(
      widget.copyWith(
        placements: {...widget.placements, orientation: placement},
      ),
    );
  }

  bool canPlace(
    String id,
    LayoutOrientation orientation,
    GridPlacement placement,
  ) {
    for (final page in pages) {
      if (page.widgets.any((widget) => widget.id == id)) {
        return _fits(page, id, orientation, placement);
      }
    }
    return false;
  }

  bool moveWidgetToPage(String id, String pageId) {
    if (!_requireEditing()) return false;
    final widget = findWidget(id);
    final target = pages.indexWhere((page) => page.id == pageId);
    if (widget == null || target < 0) return _fail('找不到组件或目标页面');
    if (pages[target].widgets.any((item) => item.id == id)) return true;
    final placements = <LayoutOrientation, GridPlacement>{};
    for (final orientation in LayoutOrientation.values) {
      final old = widget.placementFor(orientation);
      final rect = _findSpace(pages[target].widgets, orientation, old.w, old.h);
      if (rect == null) return _fail('目标页横屏或竖屏空间不足，组件仍保留在原页');
      placements[orientation] = rect;
    }
    return _apply(
      document.copyWith(
        pages: [
          for (final page in pages)
            page.copyWith(
              widgets: [
                ...page.widgets.where((item) => item.id != id),
                if (page.id == pageId) widget.copyWith(placements: placements),
              ],
            ),
        ],
        activePageId: pageId,
      ),
    );
  }

  bool arrangePage(LayoutOrientation orientation, {String? pageId}) {
    if (!_requireEditing()) return false;
    final index = pages.indexWhere(
      (page) => page.id == (pageId ?? activePage.id),
    );
    if (index < 0) return _fail('找不到页面');
    final page = pages[index];
    // Packing larger rectangles first avoids the most common fragmentation.
    final visible = page.widgets.where((widget) => widget.visible).toList()
      ..sort((a, b) {
        final ar = a.placementFor(orientation),
            br = b.placementFor(orientation);
        final area = (br.w * br.h).compareTo(ar.w * ar.h);
        return area != 0
            ? area
            : page.widgets.indexOf(a).compareTo(page.widgets.indexOf(b));
      });
    final arranged = <LayoutWidget>[];
    for (final widget in visible) {
      final old = widget.placementFor(orientation);
      final rect = _findSpace(arranged, orientation, old.w, old.h);
      if (rect == null) return _fail('现有尺寸无法自动整理，请先缩小组件');
      arranged.add(
        widget.copyWith(placements: {...widget.placements, orientation: rect}),
      );
    }
    final byId = {for (final widget in arranged) widget.id: widget};
    final next = [...pages];
    next[index] = page.copyWith(
      widgets: [for (final widget in page.widgets) byId[widget.id] ?? widget],
    );
    return _apply(document.copyWith(pages: next));
  }

  bool undo() {
    if (!canUndo) return false;
    _future.add(document);
    _draft = _history.removeLast();
    _resetSelection();
    notifyListeners();
    return true;
  }

  bool redo() {
    if (!canRedo) return false;
    _history.add(document);
    _draft = _future.removeLast();
    _resetSelection();
    notifyListeners();
    return true;
  }

  bool _replaceWidget(LayoutWidget widget) => _apply(
    document.copyWith(
      pages: [
        for (final page in pages)
          page.copyWith(
            widgets: [
              for (final old in page.widgets)
                if (old.id == widget.id) widget else old,
            ],
          ),
      ],
    ),
  );

  bool _apply(LayoutDocument next) {
    next.validate();
    error = null;
    if (jsonEncode(document.toJson()) == jsonEncode(next.toJson())) {
      notifyListeners();
      return true;
    }
    _history.add(document);
    if (_history.length > 100) _history.removeAt(0);
    _future.clear();
    _draft = next;
    if (!activePage.widgets.any((widget) => widget.id == selectedWidgetId)) {
      selectedWidgetId = null;
    }
    if (!activePage.widgets.any(
      (widget) => widget.id == focusedWidgetId && widget.visible,
    )) {
      focusedWidgetId = null;
    }
    notifyListeners();
    return true;
  }

  bool _requireEditing() => editing || _fail('请先进入编辑布局');
  bool _fail(String message) {
    error = message;
    notifyListeners();
    return false;
  }

  void _clearTransient() {
    _history.clear();
    _future.clear();
    _resetSelection();
  }

  void _resetSelection() {
    selectedWidgetId = null;
    focusedWidgetId = null;
    error = null;
  }

  String _newId(String prefix) {
    final used = <String>{
      for (final page in pages) ...[
        page.id,
        ...page.widgets.map((widget) => widget.id),
      ],
    };
    for (var attempt = 0; attempt < 100; attempt++) {
      final id = '$prefix-${_idFactory()}';
      if (!used.contains(id)) return id;
    }
    return '$prefix-${_randomId()}';
  }

  static Map<String, dynamic> defaultOptions(String type) => switch (type) {
    'sessions' => {
      'showTitle': true,
      'itemWidth': 280.0,
      'itemHeight': 96.0,
      'gap': 12.0,
      'fitRows': true,
      'density': 'normal',
    },
    'shortcuts' => {
      'showTitle': true,
      'iconSize': 56.0,
      'gapX': 16.0,
      'gapY': 16.0,
      'labels': true,
      'columns': 'auto',
    },
    'usage' => {'showTitle': true, 'content': 'quota'},
    _ => {'showTitle': true},
  };

  static GridPlacement defaultPlacement(
    String type,
    LayoutOrientation orientation,
  ) {
    if (orientation == LayoutOrientation.portrait) {
      return GridPlacement(x: 0, y: 0, w: 4, h: type == 'sessions' ? 12 : 6);
    }
    return switch (type) {
      'sessions' => const GridPlacement(x: 0, y: 0, w: 8, h: 6),
      'usage' => const GridPlacement(x: 0, y: 0, w: 4, h: 6),
      _ => const GridPlacement(x: 0, y: 0, w: 6, h: 4),
    };
  }
}

bool _fits(
  LayoutPage page,
  String id,
  LayoutOrientation orientation,
  GridPlacement rect,
) =>
    rect.fits(orientation) &&
    page.widgets.every(
      (widget) =>
          widget.id == id ||
          !widget.visible ||
          !rect.overlaps(widget.placementFor(orientation)),
    );

GridPlacement? _findSpace(
  List<LayoutWidget> widgets,
  LayoutOrientation orientation,
  int width,
  int height,
) {
  for (var y = 0; y <= orientation.rows - height; y++) {
    for (var x = 0; x <= orientation.columns - width; x++) {
      final candidate = GridPlacement(x: x, y: y, w: width, h: height);
      if (widgets.every(
        (widget) =>
            !widget.visible ||
            !candidate.overlaps(widget.placementFor(orientation)),
      )) {
        return candidate;
      }
    }
  }
  return null;
}

String _randomId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

int _integer(dynamic value) {
  if (value is! int) throw const FormatException('网格坐标必须是整数');
  return value;
}

String _string(dynamic value) {
  if (value is! String) throw const FormatException('字符串字段无效');
  return value;
}

String _nonempty(dynamic value) {
  final result = _string(value);
  if (result.trim().isEmpty) throw const FormatException('必要字段为空');
  return result;
}

Map<String, dynamic> _map(dynamic value) {
  if (value is! Map<String, dynamic>) throw const FormatException('配置对象无效');
  return value;
}

List<dynamic> _list(dynamic value) {
  if (value is! List) throw const FormatException('配置列表无效');
  return value;
}

Map<String, dynamic> _without(Map<String, dynamic> value, Set<String> keys) =>
    Map.fromEntries(value.entries.where((entry) => !keys.contains(entry.key)));
Map<String, dynamic> _frozenMap(Map<String, dynamic> value) =>
    Map.unmodifiable(value.map((key, item) => MapEntry(key, _freeze(item))));
dynamic _freeze(dynamic value) {
  if (value is Map<String, dynamic>) return _frozenMap(value);
  if (value is List) return List.unmodifiable(value.map(_freeze));
  if (value == null ||
      value is String ||
      value is bool ||
      value is num && value.isFinite) {
    return value;
  }
  throw const FormatException('配置只能包含 JSON 数据');
}

void _validateBinding(Map<String, dynamic> binding) {
  for (final entry in binding.entries) {
    if (!const {'hostId', 'source', 'resourceId'}.contains(entry.key) ||
        entry.value is! String) {
      throw const FormatException('绑定只允许主机、来源和资源 ID');
    }
  }
}

void _validateOptions(String type, Map<String, dynamic> options) {
  if (!const {'sessions', 'usage', 'shortcuts'}.contains(type)) return;
  for (final key in ['showTitle', 'fitRows', 'labels']) {
    if (options.containsKey(key) && options[key] is! bool) {
      throw const FormatException('组件开关参数无效');
    }
  }
  for (final key in [
    'itemWidth',
    'itemHeight',
    'iconSize',
    'gap',
    'gapX',
    'gapY',
  ]) {
    if (!options.containsKey(key)) continue;
    final value = options[key];
    final allowsZero = const {'gap', 'gapX', 'gapY'}.contains(key);
    if (value is! num ||
        !value.isFinite ||
        (allowsZero ? value < 0 : value <= 0)) {
      throw const FormatException('组件尺寸和间距无效');
    }
  }
}
