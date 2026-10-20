import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

const defaultSessionDisplayLimit = 20;
const maximumSessionDisplayLimit = 40;

int sessionDisplayLimit(Map<String, dynamic> options) {
  final value = options['maxSessions'];
  return value is num && value.isFinite
      ? value.round().clamp(1, maximumSessionDisplayLimit)
      : defaultSessionDisplayLimit;
}

enum LayoutOrientation { wide, portrait }

extension LayoutOrientationGrid on LayoutOrientation {
  int get columns => this == LayoutOrientation.wide ? 48 : 16;
  int get rows => this == LayoutOrientation.wide ? 48 : 96;
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

  GridPlacement scaled(int factor) =>
      GridPlacement(x: x * factor, y: y * factor, w: w * factor, h: h * factor);

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
  bool get isKnown =>
      const {'sessions', 'usage', 'shortcuts', 'statusBar'}.contains(type);

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
    // `showDetails` was removed from the layout contract. Older saved
    // documents may still contain it, but detail data is now shown in a
    // floating tooltip and must not participate in layout updates.
    'options': _without(options, const {'showDetails'}),
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
      options: _without(_map(json['options'] ?? <String, dynamic>{}), const {
        'showDetails',
      }),
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
  static const currentSchemaVersion = 3;
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
      GridPlacement portrait, {
      Map<String, dynamic> options = const {},
    }) => LayoutWidget(
      id: id,
      type: type,
      title: title,
      binding: {'source': 'codex'},
      options: {...LayoutWorkspace.defaultOptions(type), ...options},
      placements: {
        LayoutOrientation.wide: wide.scaled(4),
        LayoutOrientation.portrait: portrait.scaled(4),
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
              const GridPlacement(x: 0, y: 0, w: 8, h: 12),
              const GridPlacement(x: 0, y: 5, w: 4, h: 13),
              options: {'density': 'compact', 'itemHeight': 96.0},
            ),
            widget(
              'main-usage',
              'usage',
              'Codex 额度',
              const GridPlacement(x: 8, y: 0, w: 4, h: 6),
              const GridPlacement(x: 0, y: 0, w: 4, h: 5),
              options: {'showTitle': false},
            ),
            widget(
              'main-shortcuts',
              'shortcuts',
              '快捷入口',
              const GridPlacement(x: 8, y: 6, w: 4, h: 6),
              const GridPlacement(x: 0, y: 18, w: 4, h: 6),
              options: {'showTitle': false},
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

  /// Mark a persisted draft without leaving edit mode.
  ///
  /// If [draft] is still the current draft, replace it with the persisted
  /// document as well (for example after binding a newly created component).
  /// A newer draft made while persistence was in flight is kept intact.
  void markSaved(LayoutDocument document, {LayoutDocument? draft}) {
    document.validate();
    _committed = document;
    if (editing && (draft == null || identical(_draft, draft))) {
      _draft = document;
    }
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

  /// Append a complete, editable dashboard as one undoable change.
  String? addDashboardPage({String? hostId}) {
    if (!_requireEditing()) return null;
    final pageId = _newId('page');
    LayoutWidget part(
      String type,
      String title,
      GridPlacement wide,
      GridPlacement portrait,
      Map<String, dynamic> options,
      String source,
    ) => LayoutWidget(
      id: _newId(type),
      type: type,
      title: title,
      binding: type == 'statusBar' ? {} : {'hostId': ?hostId, 'source': source},
      options: {...defaultOptions(type), ...options},
      placements: {
        LayoutOrientation.wide: wide,
        LayoutOrientation.portrait: portrait,
      },
    );
    final page = LayoutPage(
      id: pageId,
      name: '横屏总览',
      widgets: [
        part(
          'statusBar',
          '顶部状态栏',
          const GridPlacement(x: 0, y: 0, w: 48, h: 5),
          const GridPlacement(x: 0, y: 0, w: 16, h: 10),
          {},
          '',
        ),
        part(
          'usage',
          'Codex 额度',
          const GridPlacement(x: 0, y: 5, w: 7, h: 36),
          const GridPlacement(x: 0, y: 10, w: 16, h: 18),
          {'density': 'sidebar'},
          'codex.quota',
        ),
        part(
          'sessions',
          '近期会话',
          const GridPlacement(x: 7, y: 5, w: 41, h: 36),
          const GridPlacement(x: 0, y: 28, w: 16, h: 54),
          {
            'appearance': 'cards',
            'columns': 2,
            'itemHeight': 110.0,
            'textScale': 1.35,
            'density': 'compact',
          },
          'codex.sessions',
        ),
        part(
          'shortcuts',
          '快捷入口',
          const GridPlacement(x: 0, y: 41, w: 48, h: 7),
          const GridPlacement(x: 0, y: 82, w: 16, h: 14),
          {'iconSize': 'max', 'labels': false, 'rows': 1, 'appearance': 'dock'},
          'host.shortcuts',
        ),
      ],
    );
    return _apply(
          document.copyWith(activePageId: pageId, pages: [...pages, page]),
        )
        ? pageId
        : null;
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
    final id = _newId('widget');
    final widget = LayoutWidget(
      id: id,
      type: type,
      title: title,
      binding: binding,
      options: {...defaultOptions(type), ...?options},
      placements: {
        for (final orientation in LayoutOrientation.values)
          orientation: defaultPlacement(type, orientation),
      },
    );
    final destination = _placeWidgetOnPage(page, widget);
    if (destination == null) {
      _fail('横屏或竖屏空间不足，请新建页面或先整理');
      return null;
    }
    final next = [...pages];
    next[index] = destination;
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
    GridPlacement placement, {
    bool displace = false,
  }) {
    if (!_requireEditing()) return false;
    final widget = findWidget(id);
    if (widget == null) return _fail('找不到组件');
    if (displace && widget.visible) {
      final preview = previewPlacement(id, orientation, placement);
      if (preview == null) return _fail('没有足够空间，请缩小组件或调整位置');
      return _apply(
        document.copyWith(
          pages: [
            for (final page in pages)
              page.copyWith(
                widgets: [
                  for (final widget in page.widgets)
                    if (preview[widget.id] case final rect?)
                      widget.copyWith(
                        placements: {...widget.placements, orientation: rect},
                      )
                    else
                      widget,
                ],
              ),
          ],
        ),
      );
    }
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

  /// A pure preview: displaced widgets and the active rectangle commit together
  /// on release, so a whole gesture occupies one undo entry.
  Map<String, GridPlacement>? previewPlacement(
    String id,
    LayoutOrientation orientation,
    GridPlacement placement,
  ) {
    if (!placement.fits(orientation)) return null;
    for (final page in pages) {
      if (page.widgets.any((widget) => widget.id == id && widget.visible)) {
        return _displace(page, id, orientation, placement);
      }
    }
    return null;
  }

  bool moveWidgetToPage(String id, String pageId) {
    if (!_requireEditing()) return false;
    final widget = findWidget(id);
    final target = pages.indexWhere((page) => page.id == pageId);
    if (widget == null || target < 0) return _fail('找不到组件或目标页面');
    if (pages[target].widgets.any((item) => item.id == id)) return true;
    final destination = _placeWidgetOnPage(pages[target], widget);
    if (destination == null) {
      return _fail('目标页横屏或竖屏空间不足，组件仍保留在原页');
    }
    return _apply(
      document.copyWith(
        pages: [
          for (final page in pages)
            if (page.id == pageId)
              destination
            else
              page.copyWith(
                widgets: page.widgets.where((item) => item.id != id).toList(),
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
    'statusBar' => {
      'label': 'DeskBar',
      'showClock': true,
      'showSeconds': true,
      'showConnection': true,
      'showThemeButton': true,
      'showSettingsButton': true,
    },
    'sessions' => {
      'maxSessions': defaultSessionDisplayLimit,
      'showTitle': true,
      'itemWidth': 280.0,
      'itemHeight': 96.0,
      'gap': 12.0,
      'fitRows': true,
      'density': 'normal',
    },
    'shortcuts' => {
      'showTitle': true,
      'appearance': 'plain',
      'iconSize': 'max',
      'gapX': 16.0,
      'gapY': 16.0,
      'labels': false,
      'columns': 'auto',
      'rows': 'auto',
      'alignment': 'center',
    },
    'usage' => {
      'showTitle': true,
      'content': 'quota',
      'density': 'fill',
      'alignment': 'spaceEvenly',
    },
    _ => {'showTitle': true},
  };

  static GridPlacement defaultPlacement(
    String type,
    LayoutOrientation orientation,
  ) {
    if (type == 'statusBar') {
      return GridPlacement(
        x: 0,
        y: 0,
        w: orientation.columns,
        h: orientation == LayoutOrientation.wide ? 5 : 10,
      );
    }
    if (orientation == LayoutOrientation.portrait) {
      return GridPlacement(x: 0, y: 0, w: 16, h: type == 'sessions' ? 48 : 24);
    }
    return switch (type) {
      'sessions' => const GridPlacement(x: 0, y: 0, w: 32, h: 24),
      'usage' => const GridPlacement(x: 0, y: 0, w: 16, h: 24),
      _ => const GridPlacement(x: 0, y: 0, w: 24, h: 16),
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

/// Keep the active widget fixed and relocate collisions to the nearest gap.
/// If a gap is occupied, recursively push that widget too. Locked ancestors
/// prevent cycles; a bounded search keeps crowded-page gestures responsive.
Map<String, GridPlacement>? _displace(
  LayoutPage page,
  String id,
  LayoutOrientation orientation,
  GridPlacement target,
) {
  final originals = {
    for (final widget in page.widgets)
      if (widget.visible) widget.id: widget.placementFor(orientation),
  };
  if (originals.values.fold<int>(0, (sum, rect) => sum + rect.w * rect.h) -
          originals[id]!.w * originals[id]!.h +
          target.w * target.h >
      orientation.columns * orientation.rows) {
    return null;
  }
  var positions = {...originals, id: target};
  var attempts = 2000;
  var probes = 30000;

  Map<String, GridPlacement>? resolve(Set<String> locked) {
    // Only widgets overlapping an already settled rectangle need to move.
    final collisions =
        originals.keys
            .where(
              (other) =>
                  !locked.contains(other) &&
                  locked.any(
                    (fixed) => positions[other]!.overlaps(positions[fixed]!),
                  ),
            )
            .toList()
          ..sort(
            (a, b) => (originals[b]!.w * originals[b]!.h).compareTo(
              originals[a]!.w * originals[a]!.h,
            ),
          );
    if (collisions.isEmpty) return {...positions};
    final moving = collisions.first;
    final old = originals[moving]!;
    final candidates = <GridPlacement>[];
    for (var y = 0; y <= orientation.rows - old.h; y++) {
      for (var x = 0; x <= orientation.columns - old.w; x++) {
        if (--probes < 0) return null;
        final rect = old.copyWith(x: x, y: y);
        if (locked.every((fixed) => !rect.overlaps(positions[fixed]!))) {
          candidates.add(rect);
        }
      }
    }
    bool free(GridPlacement rect) => positions.entries.every(
      (entry) => entry.key == moving || !rect.overlaps(entry.value),
    );
    final freeCandidates = candidates.where(free).toSet();
    candidates.sort((a, b) {
      final occupied = (freeCandidates.contains(a) ? 0 : 1).compareTo(
        freeCandidates.contains(b) ? 0 : 1,
      );
      if (occupied != 0) return occupied;
      final distance = ((a.x - old.x).abs() + (a.y - old.y).abs()).compareTo(
        (b.x - old.x).abs() + (b.y - old.y).abs(),
      );
      if (distance != 0) return distance;
      final row = a.y.compareTo(b.y);
      return row != 0 ? row : a.x.compareTo(b.x);
    });
    final before = {...positions};
    for (final candidate in candidates) {
      if (--attempts < 0) return null;
      positions[moving] = candidate;
      final result = resolve({...locked, moving});
      if (result != null) return result;
      positions = {...before};
    }
    return null;
  }

  return resolve({id});
}

/// Full-width status bars reserve the top edge. Preserve horizontal placement
/// and shared row boundaries below it; compress only when translation cannot fit.
/// Both profiles are prepared locally so failure cannot partially move a page.
LayoutPage? _placeWidgetOnPage(LayoutPage page, LayoutWidget widget) {
  var widgets = page.widgets.toList();
  final placements = {...widget.placements};
  for (final orientation in LayoutOrientation.values) {
    if (!widget.visible) continue;
    final old = widget.placementFor(orientation);
    if (widget.type != 'statusBar' || old.w != orientation.columns) {
      final rect = _findSpace(widgets, orientation, old.w, old.h);
      if (rect == null) return null;
      placements[orientation] = rect;
      continue;
    }
    final top = old.copyWith(x: 0, y: 0);
    placements[orientation] = top;
    final visible = widgets.where((item) => item.visible);
    if (visible.every(
      (item) => !top.overlaps(item.placementFor(orientation)),
    )) {
      continue;
    }
    final available = orientation.rows - top.h;
    if (available <= 0) return null;
    final bottom = visible.fold<int>(0, (end, item) {
      final rect = item.placementFor(orientation);
      return max(end, rect.y + rect.h);
    });
    final contentRows = max(available, bottom);
    final next = <LayoutWidget>[];
    for (final item in widgets) {
      if (!item.visible) {
        next.add(item);
        continue;
      }
      final rect = item.placementFor(orientation);
      final y = top.h + rect.y * available ~/ contentRows;
      final end = top.h + (rect.y + rect.h) * available ~/ contentRows;
      if (end <= y) return null;
      next.add(
        item.copyWith(
          placements: {
            ...item.placements,
            orientation: rect.copyWith(y: y, h: end - y),
          },
        ),
      );
    }
    widgets = next;
  }
  return page.copyWith(
    widgets: [
      ...widgets,
      widget.copyWith(placements: placements),
    ],
  );
}

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
  if (!const {'sessions', 'usage', 'shortcuts', 'statusBar'}.contains(type)) {
    return;
  }
  if (type == 'statusBar' &&
      options.containsKey('label') &&
      (options['label'] is! String ||
          (options['label'] as String).length > 80)) {
    throw const FormatException('状态栏名称最多 80 字');
  }
  if (options.containsKey('appearance') &&
      !(type == 'shortcuts'
              ? const {'plain', 'dock'}
              : const {'plain', 'cards'})
          .contains(options['appearance'])) {
    throw const FormatException('组件外观无效');
  }
  if (options.containsKey('textScale')) {
    final scale = options['textScale'];
    if (scale is! num || !scale.isFinite || scale < 1 || scale > 2) {
      throw const FormatException('文字比例需为 1 到 2');
    }
  }
  if (type == 'sessions' && options.containsKey('columns')) {
    final columns = options['columns'];
    if (columns != 'auto' && (columns is! int || columns < 1 || columns > 6)) {
      throw const FormatException('会话列数需为自动或 1 到 6');
    }
  }
  if (options.containsKey('showDetails')) {
    throw const FormatException('详细数据改为悬浮提示');
  }
  if (type == 'sessions' && options.containsKey('maxSessions')) {
    final limit = options['maxSessions'];
    if (limit is! num ||
        !limit.isFinite ||
        limit != limit.round() ||
        limit < 1 ||
        limit > maximumSessionDisplayLimit) {
      throw const FormatException('会话数量需为 1 到 40 的整数');
    }
  }
  for (final key in [
    'showTitle',
    'fitRows',
    'labels',
    'showClock',
    'showSeconds',
    'showConnection',
    'showThemeButton',
    'showSettingsButton',
  ]) {
    if (options.containsKey(key) && options[key] is! bool) {
      throw const FormatException('组件开关参数无效');
    }
  }
  for (final key in ['itemWidth', 'itemHeight', 'gap', 'gapX', 'gapY']) {
    if (!options.containsKey(key)) continue;
    final value = options[key];
    final allowsZero = const {'gap', 'gapX', 'gapY'}.contains(key);
    if (value is! num ||
        !value.isFinite ||
        (allowsZero ? value < 0 : value <= 0)) {
      throw const FormatException('组件尺寸和间距无效');
    }
  }
  if (options.containsKey('iconSize')) {
    final value = options['iconSize'];
    final valid =
        value == 'max' ||
        (value is num && value.isFinite && value > 0 && value <= 200);
    if (!valid) throw const FormatException('图标尺寸需为正数或自适应最大');
  }
  if (options.containsKey('rows')) {
    final value = options['rows'];
    final valid =
        value == 'auto' ||
        (value is num &&
            value.isFinite &&
            value == value.round() &&
            value >= 1 &&
            value <= 12);
    if (!valid) throw const FormatException('行数需为自动或 1 到 12 的整数');
  }
  if (options.containsKey('alignment')) {
    final allowed = type == 'usage'
        ? const {'top', 'center', 'spaceEvenly', 'bottom'}
        : const {'left', 'center', 'spaceEvenly', 'right'};
    if (!allowed.contains(options['alignment'])) {
      throw const FormatException('对齐方式无效');
    }
  }
  if (type == 'usage' &&
      options.containsKey('density') &&
      !const {
        'compact',
        'standard',
        'fill',
        'sidebar',
      }.contains(options['density'])) {
    throw const FormatException('用量布局密度无效');
  }
}
