import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'connection.dart';
import 'display_preferences.dart';
import 'layout_repository.dart';
import 'layout_workspace.dart';
import 'rawblock.dart';
import 'top_notice.dart';
import 'workbench_content.dart';

String widgetTypeName(String type) => switch (type) {
  'sessions' => '会话',
  'usage' => '用量',
  'shortcuts' => '快捷入口',
  _ => '未知组件',
};

String _shortcutRowsValue(dynamic value) {
  if (value is num && value.isFinite && value == value.round()) {
    final row = value.round();
    if (row >= 1 && row <= 12) return '$row';
  }
  return 'auto';
}

String _shortcutAlignmentValue(dynamic value) =>
    const {'left', 'center', 'spaceEvenly', 'right'}.contains(value)
    ? value as String
    : 'spaceEvenly';

List<Widget> _inspectorFields(List<Widget> fields, {double gap = 12}) => [
  for (var i = 0; i < fields.length; i++) ...[
    fields[i],
    if (i + 1 < fields.length) SizedBox(height: gap),
  ],
];

class WorkbenchCanvas extends StatefulWidget {
  const WorkbenchCanvas({
    super.key,
    required this.connection,
    this.workspace,
    this.repository,
    this.displayPreferences,
    this.onEditingChanged,
    this.onConnectionSettings,
    this.allowEditing = false,
    this.previewSize,
    this.previewFit = true,
    this.previewTextScale = 1,
    this.debugLayout = false,
  });
  final bool allowEditing, debugLayout;
  final bool previewFit;
  final double previewTextScale;
  final Size? previewSize;
  final Connection connection;
  final LayoutWorkspace? workspace;
  final LayoutRepository? repository;
  final DisplayPreferences? displayPreferences;
  final ValueChanged<bool>? onEditingChanged;
  final VoidCallback? onConnectionSettings;
  @override
  State<WorkbenchCanvas> createState() => _WorkbenchCanvasState();
}

class _WorkbenchCanvasState extends State<WorkbenchCanvas> {
  late final LayoutWorkspace workspace = widget.workspace ?? LayoutWorkspace();
  late final LayoutRepository repository =
      widget.repository ?? LayoutRepository();
  late final PageController pages = PageController(initialPage: _pageIndex);
  final storage = PageStorageBucket();
  late final DisplayPreferences display =
      widget.displayPreferences ?? DisplayPreferences();
  String? panel, inspectedId;
  final editorFocus = FocusNode(debugLabel: 'Desktop canvas');
  bool outlineTab = true;
  bool get desktopEditor => widget.allowEditing && widget.previewSize != null;
  bool reportedEditing = false;
  Size viewport = Size.zero;
  bool bindingQueued = false;
  Timer? _persist, _displayTimer, _autoSave;
  Future<bool>? _saveOperation;
  LayoutDocument? _lastSavedDocument, _observedDocument;
  String? _remoteKey, _lastReport;
  bool loading = true, saving = false, _syncing = false, readOnly = false;
  String? warning, _activeId;
  DateTime _lastWheel = DateTime.fromMillisecondsSinceEpoch(0);
  LayoutOrientation orientation = LayoutOrientation.portrait;
  Map<String, GridPlacement>? placementPreview;
  int get _pageIndex =>
      workspace.pages.indexWhere((p) => p.id == workspace.activePage.id);
  @override
  void initState() {
    super.initState();
    workspace.addListener(_changed);
    display.addListener(_displayChanged);
    widget.connection.addListener(_connectionChanged);
    _activeId = workspace.activePage.id;
    _lastSavedDocument = workspace.document;
    _observedDocument = workspace.document;
    if (!widget.allowEditing) {
      loading = false;
      _syncRemoteLayout();
      _displayTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _reportDisplay(force: true),
      );
    } else if (widget.workspace != null) {
      loading = false;
      _scheduleBinding();
    } else {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      final loaded = await repository.load();
      if (!mounted) return;
      workspace.replaceDocument(loaded.document);
      warning = loaded.warning;
      readOnly = loaded.readOnly;
    } catch (_) {
      warning = '未能读取布局，当前使用初始布局。编辑时会自动尝试更新。';
    }
    if (mounted) {
      setState(() => loading = false);
      _scheduleBinding();
    }
  }

  @override
  void dispose() {
    _persist?.cancel();
    _autoSave?.cancel();
    _displayTimer?.cancel();
    workspace.removeListener(_changed);
    widget.connection.removeListener(_connectionChanged);
    if (widget.workspace == null) workspace.dispose();
    pages.dispose();
    editorFocus.dispose();
    display.removeListener(_displayChanged);
    if (widget.displayPreferences == null) display.dispose();
    super.dispose();
  }

  void _displayChanged() {
    if (mounted) setState(() {});
  }

  void _connectionChanged() {
    if (!mounted) return;
    _syncRemoteLayout();
    setState(() {});
    _scheduleBinding();
  }

  void _scheduleBinding() {
    if (!widget.allowEditing ||
        widget.previewSize != null ||
        bindingQueued ||
        loading ||
        workspace.editing ||
        saving ||
        widget.connection.data == null) {
      return;
    }
    bindingQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bindingQueued = false;
      if (!mounted || loading || workspace.editing || saving) return;
      final next = _bindDocument(workspace.document);
      if (identical(next, workspace.document)) return;
      workspace.replaceDocument(next);
      if (!readOnly) {
        unawaited(
          repository.save(next).catchError((Object error) {
            if (mounted) _toast('组件已绑定此电脑，但布局更新失败。请稍后重试。');
          }),
        );
      }
    });
  }

  LayoutDocument _bindDocument(LayoutDocument document) {
    final hostId = widget.connection.data?.hostId;
    if (hostId == null || hostId.isEmpty) return document;
    var changed = false;
    final next = [
      for (final page in document.pages)
        page.copyWith(
          widgets: [
            for (final w in page.widgets)
              if (w.binding['hostId'] == null || w.binding['hostId'] == '')
                (() {
                  changed = true;
                  final oldSource = w.binding['source'];
                  return w.copyWith(
                    binding: {
                      ...w.binding,
                      'hostId': hostId,
                      if (oldSource == null ||
                          oldSource == '' ||
                          oldSource == 'codex')
                        'source': switch (w.type) {
                          'sessions' => 'codex.sessions',
                          'shortcuts' => 'host.shortcuts',
                          'usage' =>
                            w.options['content'] == 'api'
                                ? 'sub2api.usage'
                                : 'codex.quota',
                          _ => oldSource ?? '',
                        },
                    },
                  );
                })()
              else
                w,
          ],
        ),
    ];
    return changed ? document.copyWith(pages: next) : document;
  }

  void _changed() {
    if (!mounted) return;
    placementPreview = null;
    _scheduleBinding();
    if (!workspace.editing) {
      panel = null;
      inspectedId = null;
    }
    if (reportedEditing != workspace.editing) {
      reportedEditing = workspace.editing;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onEditingChanged?.call(workspace.editing);
      });
    }
    final activeChanged = _activeId != workspace.activePage.id;
    _activeId = workspace.activePage.id;
    setState(() {});
    _syncing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (pages.hasClients && (pages.page ?? 0).round() != _pageIndex) {
        pages.jumpToPage(_pageIndex);
      }
      _syncing = false;
    });
    if (widget.allowEditing &&
        widget.previewSize == null &&
        activeChanged &&
        !workspace.editing &&
        !readOnly &&
        !loading) {
      _persist?.cancel();
      _persist = Timer(
        const Duration(milliseconds: 250),
        () => unawaited(_saveNavigation()),
      );
    }
    final documentChanged = !identical(_observedDocument, workspace.document);
    _observedDocument = workspace.document;
    if (documentChanged && workspace.editing) _scheduleAutoSave();
  }

  Future<void> _saveNavigation() async {
    try {
      await repository.save(workspace.committed);
    } catch (_) {
      if (mounted) _toast('页面选择更新失败，布局仍可使用。');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showTopNotice(context, message);
  }

  void _result(bool success) {
    if (!success) _toast(workspace.error ?? '未能完成修改');
  }

  void _desktopHistory({bool redo = false}) {
    final id = workspace.selectedWidgetId ?? inspectedId;
    final changed = redo ? workspace.redo() : workspace.undo();
    if (changed && workspace.activePage.widgets.any((w) => w.id == id)) {
      workspace.selectWidget(id);
    }
  }

  // Text fields keep their native editing shortcuts. Canvas commands only run
  // when no text editor or modal route owns focus.
  KeyEventResult _desktopKey(KeyEvent event) {
    if (ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus;
    final typing =
        focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isMetaPressed || keyboard.isControlPressed;
    if (typing) return KeyEventResult.ignored;
    if (command &&
        (key == LogicalKeyboardKey.keyZ || key == LogicalKeyboardKey.keyY)) {
      if (event is KeyDownEvent) {
        if (keyboard.isShiftPressed || key == LogicalKeyboardKey.keyY) {
          _desktopHistory(redo: true);
        } else {
          _desktopHistory();
        }
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _closePanel();
      return KeyEventResult.handled;
    }
    final selected = workspace.selectedWidget;
    if (selected == null ||
        !workspace.editing ||
        command ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (event is KeyDownEvent) {
        workspace.removeWidget(selected.id);
        _closePanel();
      }
      return KeyEventResult.handled;
    }
    final step = keyboard.isShiftPressed ? 10 : 1;
    final delta = switch (key) {
      LogicalKeyboardKey.arrowLeft => Offset(-step.toDouble(), 0),
      LogicalKeyboardKey.arrowRight => Offset(step.toDouble(), 0),
      LogicalKeyboardKey.arrowUp => Offset(0, -step.toDouble()),
      LogicalKeyboardKey.arrowDown => Offset(0, step.toDouble()),
      _ => null,
    };
    if (delta == null || !selected.visible) return KeyEventResult.ignored;
    final r = selected.placementFor(orientation);
    final next = r.copyWith(
      x: (r.x + delta.dx.toInt()).clamp(0, orientation.columns - r.w),
      y: (r.y + delta.dy.toInt()).clamp(0, orientation.rows - r.h),
    );
    if (next != r) {
      _result(
        workspace.setPlacement(selected.id, orientation, next, displace: true),
      );
    }
    return KeyEventResult.handled;
  }

  void _syncRemoteLayout() {
    if (widget.allowEditing) return;
    final data = widget.connection.data;
    if (data == null) return;
    final key = '${data.hostId}/${data.epoch}/${data.layoutRevision}';
    if (key == _remoteKey) return;
    final current = workspace.activePage.id;
    final sameHost = _remoteKey?.startsWith('${data.hostId}/') ?? false;
    _remoteKey = key;
    final next = data.layout;
    workspace.replaceDocument(
      sameHost && next.pages.any((p) => p.id == current)
          ? next.copyWith(activePageId: current)
          : next,
    );
  }

  void _reportDisplay({bool force = false}) {
    if (!mounted || widget.allowEditing || viewport.isEmpty) return;
    final data = widget.connection.data;
    if (data == null) return;
    final report = <String, dynamic>{
      'width': viewport.width,
      'height': viewport.height,
      'text_scale': MediaQuery.textScalerOf(context).scale(14) / 14,
      'dark': Theme.of(context).brightness == Brightness.dark,
      'page_id': workspace.activePage.id,
      'layout_revision': data.layoutRevision,
    };
    final encoded = jsonEncode(report);
    if (!force && encoded == _lastReport) return;
    _lastReport = encoded;
    unawaited(widget.connection.reportDisplay(report));
  }

  void _begin() {
    if (!widget.allowEditing) {
      widget.onConnectionSettings?.call();
      return;
    }
    if (readOnly || loading) {
      _toast(readOnly ? '请升级工作台后再编辑布局。' : '正在读取布局，请稍候。');
      return;
    }
    _persist?.cancel();
    workspace.beginEdit();
  }

  void _scheduleAutoSave() {
    if (!widget.allowEditing ||
        !desktopEditor ||
        !workspace.editing ||
        loading ||
        readOnly) {
      return;
    }
    _autoSave?.cancel();
    _autoSave = Timer(const Duration(milliseconds: 450), () {
      _autoSave = null;
      unawaited(_saveDraft());
    });
  }

  Future<bool> _saveDraft({bool flush = false}) async {
    if (!widget.allowEditing || !workspace.editing || loading || readOnly) {
      return false;
    }
    final active = _saveOperation;
    if (active != null) {
      if (!flush) return false;
      final success = await active;
      if (!success) return false;
      if (!identical(workspace.document, _lastSavedDocument)) {
        return _saveDraft(flush: true);
      }
      return true;
    }
    if (identical(workspace.document, _lastSavedDocument)) return true;

    final draft = workspace.document;
    final savedDocument = _bindDocument(draft);
    if (mounted) setState(() => saving = true);
    late final Future<bool> operation;
    operation = () async {
      try {
        await repository.save(savedDocument);
        if (!mounted) return true;
        workspace.markSaved(savedDocument, draft: draft);
        _lastSavedDocument = savedDocument;
        _observedDocument = workspace.document;
        return true;
      } catch (_) {
        if (mounted) _toast('布局更新失败，请稍后重试。');
        return false;
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }();
    _saveOperation = operation;
    final success = await operation;
    if (identical(_saveOperation, operation)) _saveOperation = null;
    if (success &&
        workspace.editing &&
        !identical(workspace.document, _lastSavedDocument)) {
      if (flush) return _saveDraft(flush: true);
      _scheduleAutoSave();
    }
    return success;
  }

  Future<void> _finish() async {
    _autoSave?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    // Commit numeric property fields before flushing the pending draft.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    if (await _saveDraft(flush: true) && mounted) workspace.commitEdit();
  }

  void _navigate(String id) {
    if (workspace.activePage.id != id) {
      panel = null;
      inspectedId = null;
    }
    workspace.setActivePage(id);
  }

  void _step(int delta) {
    if (workspace.editing) return;
    final next = (_pageIndex + delta).clamp(0, workspace.pages.length - 1);
    _navigate(workspace.pages[next].id);
  }

  void _closePanel() => setState(() {
    panel = null;
    inspectedId = null;
    workspace.selectWidget(null);
  });
  void _openPanel(String name) {
    _begin();
    if (!workspace.editing) return;
    setState(() {
      panel = name;
      inspectedId = null;
      workspace.selectWidget(null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = deskbarColors(context);
    return PopScope(
      canPop: !workspace.editing && !display.immersive,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (panel != null) {
          _closePanel();
        } else if (workspace.editing) {
          unawaited(_finish());
        } else if (display.immersive) {
          unawaited(display.setImmersive(false));
        }
      },
      child: Focus(
        focusNode: editorFocus,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (desktopEditor &&
              (event is KeyDownEvent || event is KeyRepeatEvent)) {
            return _desktopKey(event);
          }
          if (event is! KeyDownEvent || workspace.editing) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _step(-1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _step(1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          children: [
            if (warning != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 48),
                child: Material(
                  color: c.warningBg,
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            warning!,
                            style: TextStyle(color: c.warning, fontSize: 12),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭提示',
                        onPressed: () => setState(() => warning = null),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            if (widget.allowEditing)
              desktopEditor ? _desktopToolbar() : _editToolbar(),
            if (widget.allowEditing && !desktopEditor)
              const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final nextOrientation =
                      (widget.previewSize?.aspectRatio ??
                              MediaQuery.sizeOf(context).aspectRatio) >
                          1
                      ? LayoutOrientation.wide
                      : LayoutOrientation.portrait;
                  if (orientation != nextOrientation) placementPreview = null;
                  orientation = nextOrientation;
                  final canvas = loading
                      ? const Center(child: CircularProgressIndicator())
                      : widget.previewSize == null
                      ? _canvas()
                      : _desktopPreview();
                  if (!widget.allowEditing) return canvas;
                  if (desktopEditor) return _desktopWorkspace(box, canvas);
                  final inspector = panel == null
                      ? const Center(child: Text('选择组件'))
                      : _editorPanel();
                  // Dock against the device orientation, not the host window.
                  // Reserve its space before selection to keep drag geometry stable.
                  if (orientation == LayoutOrientation.wide) {
                    return Column(
                      children: [
                        Expanded(child: canvas),
                        const SizedBox(height: 12),
                        SizedBox(
                          key: const ValueKey('editor-inspector'),
                          height: math.min(260, box.maxHeight * .45),
                          child: inspector,
                        ),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: canvas),
                      const SizedBox(width: 12),
                      SizedBox(
                        key: const ValueKey('editor-inspector'),
                        width: math.min(300, box.maxWidth * .5),
                        child: inspector,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _desktopPreview() {
    final c = deskbarColors(context);
    final screen = SizedBox.fromSize(
      size: widget.previewSize,
      child: ColoredBox(
        color: c.canvas,
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(widget.previewTextScale)),
          child: _canvas(),
        ),
      ),
    );
    return ColoredBox(
      color: c.sidebar,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: widget.previewFit
            ? Center(
                child: FittedBox(fit: BoxFit.contain, child: screen),
              )
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(child: screen),
              ),
      ),
    );
  }

  Widget _desktopToolbar() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                PopupMenuButton<String>(
                  tooltip: '添加组件',
                  onSelected: (type) {
                    _begin();
                    if (workspace.editing) unawaited(_createWidget(type));
                  },
                  itemBuilder: (_) => [
                    for (final type in ['sessions', 'usage', 'shortcuts'])
                      PopupMenuItem(
                        value: type,
                        child: Text(widgetTypeName(type)),
                      ),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.add, size: 18),
                        SizedBox(width: 6),
                        Text('添加组件'),
                        Icon(Icons.expand_more, size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  tooltip: '撤销 · ⌘ / Ctrl Z',
                  onPressed: workspace.canUndo ? _desktopHistory : null,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  tooltip: '重做 · ⌘ / Ctrl Shift Z',
                  onPressed: workspace.canRedo
                      ? () => _desktopHistory(redo: true)
                      : null,
                  icon: const Icon(Icons.redo),
                ),
                IconButton(
                  tooltip: '整理本页',
                  onPressed: () {
                    _begin();
                    _result(workspace.arrangePage(orientation));
                  },
                  icon: const Icon(Icons.auto_awesome_mosaic_outlined),
                ),
              ],
            ),
          ),
        ),
        FilledButton(
          onPressed: !workspace.editing ? null : _finish,
          child: Text(saving ? '更新中…' : '完成'),
        ),
      ],
    ),
  );

  Widget _desktopWorkspace(BoxConstraints box, Widget canvas) {
    final c = deskbarColors(context);
    final inspector = SizedBox(
      key: const ValueKey('editor-inspector'),
      child: panel == 'widget' && inspectedId != null
          ? _editorPanel()
          : ColoredBox(
              color: c.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sectionHeading('属性'),
                  const Expanded(child: Center(child: Text('选择画布或列表中的组件'))),
                ],
              ),
            ),
    );
    final stage = Column(
      children: [
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    workspace.activePage.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  orientation == LayoutOrientation.wide ? '横屏布局' : '竖屏布局',
                  style: TextStyle(color: c.muted, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: canvas),
        SizedBox(
          height: 36,
          child: Center(
            child: Text(
              '方向键微调 · Shift 加速 · Delete 删除 · Esc 取消选择',
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ),
        ),
      ],
    );
    // The host window determines editor chrome. Device rotation changes only
    // the canvas and the independent orientation placement being edited.
    if (box.maxWidth >= 1000) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 220, child: _desktopOutline()),
          const SizedBox(width: 12),
          Expanded(child: stage),
          const SizedBox(width: 12),
          SizedBox(width: 300, child: inspector),
        ],
      );
    }
    if (box.maxWidth >= 700) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: stage),
          const SizedBox(width: 12),
          SizedBox(
            width: 280,
            child: Column(
              children: [
                _outlineTabs(),
                Expanded(child: outlineTab ? _desktopOutline() : inspector),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        Expanded(child: stage),
        _outlineTabs(),
        SizedBox(
          height: math.min(300, box.maxHeight * .45),
          child: outlineTab ? _desktopOutline() : inspector,
        ),
      ],
    );
  }

  Widget _outlineTabs() => Row(
    children: [
      for (final entry in [(true, '页面与组件'), (false, '属性')])
        Expanded(
          child: TextButton(
            style: TextButton.styleFrom(
              backgroundColor: outlineTab == entry.$1
                  ? deskbarColors(context).selection
                  : null,
            ),
            onPressed: () => setState(() => outlineTab = entry.$1),
            child: Text(entry.$2),
          ),
        ),
    ],
  );

  Widget _sectionHeading(String title, {Widget? action}) => SizedBox(
    height: 44,
    child: Padding(
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
          ?action,
        ],
      ),
    ),
  );

  Widget _desktopOutline() => Material(
    key: const ValueKey('editor-outline'),
    color: deskbarColors(context).surface,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 2, child: _pagesBody()),
        Divider(height: 1, color: deskbarColors(context).line),
        _sectionHeading('本页组件'),
        Expanded(flex: 3, child: _componentsBody()),
      ],
    ),
  );

  Widget _editToolbar() => Material(
    color: deskbarColors(context).canvas,
    child: SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  PopupMenuButton<String>(
                    tooltip: '切换编辑页面',
                    onSelected: (id) {
                      _begin();
                      _navigate(id);
                    },
                    itemBuilder: (context) => [
                      for (final p in workspace.pages)
                        PopupMenuItem(value: p.id, child: Text(p.name)),
                    ],
                    child: SizedBox(
                      height: 48,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Text(
                              '${_pageIndex + 1}/${workspace.pages.length} ${workspace.activePage.name}',
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.expand_more, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '撤销',
                    onPressed: workspace.canUndo ? workspace.undo : null,
                    icon: const Icon(Icons.undo),
                  ),
                  IconButton(
                    tooltip: '重做',
                    onPressed: workspace.canRedo ? workspace.redo : null,
                    icon: const Icon(Icons.redo),
                  ),
                  IconButton(
                    tooltip: '添加组件',
                    onPressed: _addWidget,
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    tooltip: '显示的组件',
                    onPressed: _components,
                    icon: const Icon(Icons.layers_outlined),
                  ),
                  IconButton(
                    tooltip: '管理页面',
                    onPressed: _managePages,
                    icon: const Icon(Icons.tab_outlined),
                  ),
                  IconButton(
                    tooltip: '整理本页',
                    onPressed: () {
                      _begin();
                      _result(workspace.arrangePage(orientation));
                    },
                    icon: const Icon(Icons.auto_awesome_mosaic_outlined),
                  ),
                ],
              ),
            ),
          ),
          FilledButton(
            onPressed: !workspace.editing ? null : _finish,
            child: Text(saving ? '更新中…' : '完成'),
          ),
        ],
      ),
    ),
  );
  Widget _canvas() => LayoutBuilder(
    builder: (context, box) {
      if (viewport != box.biggest) placementPreview = null;
      viewport = box.biggest;
      if (!widget.allowEditing) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _reportDisplay());
      }
      return Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent &&
              !workspace.editing &&
              event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs() &&
              event.scrollDelta.dx.abs() > 8 &&
              DateTime.now().difference(_lastWheel).inMilliseconds > 550) {
            _lastWheel = DateTime.now();
            _step(event.scrollDelta.dx > 0 ? 1 : -1);
          }
        },
        child: PageStorage(
          bucket: storage,
          child: PageView.builder(
            controller: pages,
            physics: workspace.editing
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            onPageChanged: (index) {
              if (!_syncing && index < workspace.pages.length) {
                _navigate(workspace.pages[index].id);
              }
            },
            itemCount: workspace.pages.length,
            itemBuilder: (context, index) => _page(workspace.pages[index]),
          ),
        ),
      );
    },
  );
  Widget _page(LayoutPage page) {
    final visible = page.widgets.where((w) => w.visible).toList();
    return Padding(
      padding: const EdgeInsets.all(2),
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: ValueKey('page-edit-background-${page.id}'),
                behavior: HitTestBehavior.opaque,
                onLongPress: workspace.editing ? null : _begin,
                onTap: widget.allowEditing ? _closePanel : null,
                child: workspace.editing
                    ? CustomPaint(
                        painter: _GridPainter(
                          orientation,
                          deskbarColors(context).line,
                        ),
                      )
                    : const SizedBox(),
              ),
            ),
            if (visible.isEmpty)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: workspace.editing ? null : _begin,
                  child: Center(
                    child: workspace.editing
                        ? OutlinedButton(
                            onPressed: _components,
                            child: const Text('选择组件'),
                          )
                        : const SizedBox(),
                  ),
                ),
              ),
            for (final w in visible)
              _PlacedWidget(
                key: ValueKey('${page.id}-${w.id}-${orientation.name}'),
                widget: w,
                orientation: orientation,
                size: box.biggest,
                workspace: workspace,
                connection: widget.connection,
                onError: _toast,
                onSettings: () => _inspect(w.id),
                onEditRequested: _begin,
                exactPreview: widget.previewSize != null,
                editable: widget.allowEditing,
                debugLayout: widget.debugLayout,
                preview: placementPreview?[w.id],
                onPreview: (preview) =>
                    setState(() => placementPreview = preview),
              ),
          ],
        ),
      ),
    );
  }

  Widget _editorPanel() {
    final title = switch (panel) {
      'widget' =>
        '${widgetTypeName(workspace.findWidget(inspectedId)?.type ?? '')}设置',
      'components' => '显示的组件',
      'pages' => '管理页面',
      'add' => '添加组件',
      _ => '组件属性',
    };
    final body = switch (panel) {
      'widget' => _widgetInspector(),
      'components' => _componentsBody(),
      'pages' => _pagesBody(),
      'add' => ListView(
        children: [
          for (final t in ['sessions', 'usage', 'shortcuts'])
            ListTile(
              title: Text(widgetTypeName(t)),
              onTap: () => _createWidget(t),
            ),
        ],
      ),
      _ => const SizedBox(),
    };
    final heading = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );
    return Material(
      color: deskbarColors(context).surface,
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: heading),
                IconButton(
                  tooltip: '关闭设置',
                  onPressed: _closePanel,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey('editor-panel-$panel-${inspectedId ?? ''}'),
              child: body,
            ),
          ),
        ],
      ),
    );
  }

  Future<String?> _askName(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: '页面名称'),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    return result;
  }

  Future<void> _managePages() async {
    _openPanel('pages');
  }

  Widget _pagesBody() => Column(
    children: [
      if (desktopEditor)
        _sectionHeading(
          '页面',
          action: IconButton(
            tooltip: '新建页面',
            onPressed: _newPage,
            icon: const Icon(Icons.add, size: 18),
          ),
        )
      else
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _newPage,
            icon: const Icon(Icons.add),
            label: const Text('新建页面'),
          ),
        ),
      Expanded(
        child: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          onReorderItem: (oldIndex, newIndex) {
            _begin();
            _result(workspace.movePage(workspace.pages[oldIndex].id, newIndex));
          },
          itemCount: workspace.pages.length,
          itemBuilder: (context, index) {
            final p = workspace.pages[index];
            return ListTile(
              key: ValueKey(p.id),
              selected: desktopEditor && workspace.activePage.id == p.id,
              selectedTileColor: deskbarColors(context).selection,
              selectedColor: deskbarColors(context).selectedText,
              dense: desktopEditor,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              minLeadingWidth: 24,
              leading: ReorderableDragStartListener(
                index: index,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: SizedBox(
                    width: desktopEditor ? 24 : 48,
                    height: desktopEditor ? 36 : 48,
                    child: const Icon(Icons.drag_handle, size: 18),
                  ),
                ),
              ),
              title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () {
                _begin();
                _navigate(p.id);
                editorFocus.requestFocus();
              },
              trailing: PopupMenuButton<String>(
                tooltip: '页面操作 ${p.name}',
                onSelected: (action) async {
                  if (action == 'rename') {
                    final name = await _askName('重命名页面', p.name);
                    if (name != null && mounted) {
                      _begin();
                      _result(workspace.renamePage(p.id, name));
                    }
                  } else {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        scrollable: true,
                        title: Text('删除「${p.name}」？'),
                        content: const Text('页面和其中的组件会一并删除。本次编辑完成前可以撤销。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('删除页面'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true && mounted) {
                      _begin();
                      _result(workspace.deletePage(p.id));
                    }
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(
                    value: 'delete',
                    enabled: workspace.pages.length > 1,
                    child: const Text('删除'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );
  Future<void> _newPage() async {
    final name = await _askName('新建空白页', '新页面');
    if (name == null || !mounted) return;
    _begin();
    workspace.addPage(name: name);
    if (desktopEditor) _closePanel();
  }

  Future<void> _addWidget() async {
    _openPanel('add');
  }

  Future<void> _createWidget(String type) async {
    Map<String, dynamic> binding() => {
      if (widget.connection.data != null)
        'hostId': widget.connection.data!.hostId,
      'source': type == 'sessions'
          ? 'codex.sessions'
          : type == 'usage'
          ? 'codex.quota'
          : 'host.shortcuts',
    };
    var id = workspace.addWidget(
      type,
      title: widgetTypeName(type),
      binding: binding(),
    );
    if (id == null) {
      final create = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('当前页面放不下'),
          content: Text(workspace.error ?? '请先缩小组件或新建页面。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回整理'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('新建页面并添加'),
            ),
          ],
        ),
      );
      if (create == true && mounted) {
        workspace.addPage();
        id = workspace.addWidget(
          type,
          title: widgetTypeName(type),
          binding: binding(),
        );
      }
    }
    if (id != null && mounted) {
      workspace.selectWidget(id);
      unawaited(_inspect(id));
    }
  }

  Future<void> _components() async {
    _openPanel('components');
  }

  Widget _componentsBody() => ListView(
    children: [
      for (final w in workspace.activePage.widgets)
        ListTile(
          key: ValueKey('outline-${w.id}'),
          dense: desktopEditor,
          selected: workspace.selectedWidgetId == w.id,
          selectedTileColor: deskbarColors(context).selection,
          selectedColor: deskbarColors(context).selectedText,
          minLeadingWidth: 24,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: desktopEditor
              ? Icon(switch (w.type) {
                  'sessions' => Icons.view_agenda_outlined,
                  'usage' => Icons.donut_large_outlined,
                  _ => Icons.apps_outlined,
                }, size: 18)
              : Checkbox(
                  value: w.visible,
                  onChanged: (v) =>
                      _result(workspace.setWidgetVisible(w.id, v ?? false)),
                ),
          title: Text(
            w.title.isEmpty ? widgetTypeName(w.type) : w.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _inspect(w.id),
          trailing: IconButton(
            tooltip: desktopEditor ? (w.visible ? '隐藏组件' : '显示组件') : '设置组件',
            onPressed: () {
              if (!desktopEditor) {
                _inspect(w.id);
                return;
              }
              _begin();
              _result(workspace.setWidgetVisible(w.id, !w.visible));
            },
            icon: Icon(
              desktopEditor
                  ? (w.visible
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined)
                  : Icons.tune,
              size: 18,
            ),
          ),
        ),
      if (workspace.activePage.widgets.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('从工具栏添加组件')),
      if (!desktopEditor)
        TextButton.icon(
          onPressed: _addWidget,
          icon: const Icon(Icons.add),
          label: const Text('添加组件'),
        ),
    ],
  );
  Future<void> _inspect(String id) async {
    _begin();
    if (!workspace.editing) return;
    workspace.selectWidget(id);
    setState(() {
      panel = 'widget';
      inspectedId = id;
      if (desktopEditor) outlineTab = false;
    });
    if (desktopEditor) editorFocus.requestFocus();
  }

  Widget _widgetInspector() {
    final id = inspectedId;
    final w = workspace.findWidget(id);
    if (id == null || w == null) {
      return const Center(child: Text('组件已移除，可撤销恢复。'));
    }
    final groups = <Widget>[
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _inspectorFields([
          _WidgetNameField(
            key: ValueKey('name-editor-$id'),
            id: id,
            value: w.title,
            onChanged: (v) => workspace.updateWidget(id, title: v),
          ),
          if (desktopEditor) _placementControls(w),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('显示组件'),
            value: w.visible,
            onChanged: (v) => _result(workspace.setWidgetVisible(id, v)),
          ),
          _bindingControls(w),
        ]),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _inspectorFields([
          if (w.type == 'sessions') ...[
            _optionSlider(w, 'itemWidth', '卡片目标宽度', 120, 600, 280),
            _optionSlider(
              w,
              'itemHeight',
              '卡片目标高度',
              w.options['density'] == 'compact' ? 88 : 140,
              400,
              96,
            ),
            _optionSlider(w, 'gap', '卡片间距', 0, 40, 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              isThreeLine: true,
              title: const Text('自动铺满完整行'),
              subtitle: const Text('根据目标高度计算完整行数，大字号时增加最小高度。'),
              value: w.options['fitRows'] != false,
              onChanged: (v) =>
                  workspace.updateWidget(id, options: {'fitRows': v}),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('density-$id-${w.options['density']}'),
              initialValue: w.options['density'] == 'compact'
                  ? 'compact'
                  : 'normal',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '会话信息'),
              items: const [
                DropdownMenuItem(
                  value: 'normal',
                  child: Text(
                    '标准',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'compact',
                  child: Text(
                    '精简',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                final minimum = v == 'compact' ? 88.0 : 140.0;
                final current = (w.options['itemHeight'] as num?)?.toDouble();
                workspace.updateWidget(
                  id,
                  options: {
                    'density': v,
                    if (current != null && current < minimum)
                      'itemHeight': minimum,
                  },
                );
              },
            ),
          ],
          if (w.type == 'shortcuts') ...[
            DropdownButtonFormField<String>(
              key: ValueKey('icon-size-mode-$id-${w.options['iconSize']}'),
              initialValue: w.options['iconSize'] == 'max' ? 'max' : 'fixed',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '图标尺寸'),
              items: const [
                DropdownMenuItem(
                  value: 'fixed',
                  child: Text(
                    '固定尺寸',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'max',
                  child: Text(
                    '自适应最大',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (v) => workspace.updateWidget(
                id,
                options: {
                  'iconSize': v == 'max'
                      ? 'max'
                      : (w.options['iconSize'] is num
                            ? w.options['iconSize']
                            : 56.0),
                },
              ),
            ),
            if (w.options['iconSize'] != 'max')
              _optionSlider(w, 'iconSize', '固定图标大小', 24, 200, 56),
            _optionSlider(w, 'gapX', '横向间距', 0, 64, 16),
            _optionSlider(w, 'gapY', '纵向间距', 0, 64, 16),
            DropdownButtonFormField<String>(
              key: ValueKey('shortcut-rows-$id-${w.options['rows']}'),
              initialValue: _shortcutRowsValue(w.options['rows']),
              isExpanded: true,
              decoration: const InputDecoration(labelText: '行数'),
              items: [
                const DropdownMenuItem(
                  value: 'auto',
                  child: Text(
                    '自动',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                for (var row = 1; row <= 12; row++)
                  DropdownMenuItem(
                    value: '$row',
                    child: Text(
                      '$row 行',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => workspace.updateWidget(
                id,
                options: {'rows': v == 'auto' ? 'auto' : int.parse(v!)},
              ),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('shortcut-alignment-$id-${w.options['alignment']}'),
              initialValue: _shortcutAlignmentValue(w.options['alignment']),
              isExpanded: true,
              decoration: const InputDecoration(labelText: '对齐方式'),
              items: const [
                DropdownMenuItem(
                  value: 'left',
                  child: Text(
                    '左对齐',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'center',
                  child: Text(
                    '居中对齐',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'spaceEvenly',
                  child: Text(
                    '均匀分布',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'right',
                  child: Text(
                    '右对齐',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (v) => workspace.updateWidget(
                id,
                options: {'alignment': v ?? 'spaceEvenly'},
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示名称'),
              value: w.options['labels'] != false,
              onChanged: (v) =>
                  workspace.updateWidget(id, options: {'labels': v}),
            ),
          ],
          if (w.type == 'usage') ...[
            DropdownButtonFormField<String>(
              key: ValueKey('content-$id-${w.options['content']}'),
              initialValue: w.options['content'] == 'api' ? 'api' : 'quota',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '用量内容'),
              items: const [
                DropdownMenuItem(
                  value: 'quota',
                  child: Text(
                    'Codex 额度',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'api',
                  child: Text(
                    'API 用量',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (v) => workspace.updateWidget(
                id,
                options: {'content': v},
                binding: {
                  if (widget.connection.data != null)
                    'hostId': widget.connection.data!.hostId,
                  'source': v == 'api' ? 'sub2api.usage' : 'codex.quota',
                },
              ),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('usage-density-$id-${w.options['density']}'),
              initialValue: switch (w.options['density']) {
                'compact' => 'compact',
                'standard' => 'standard',
                _ => 'fill',
              },
              isExpanded: true,
              decoration: const InputDecoration(labelText: '内容布局'),
              items: const [
                DropdownMenuItem(
                  value: 'fill',
                  child: Text(
                    '自适应填充',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'standard',
                  child: Text(
                    '标准',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'compact',
                  child: Text(
                    '紧凑',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (v) =>
                  workspace.updateWidget(id, options: {'density': v ?? 'fill'}),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('usage-alignment-$id-${w.options['alignment']}'),
              initialValue: switch (w.options['alignment']) {
                'top' => 'top',
                'center' => 'center',
                'bottom' => 'bottom',
                _ => 'spaceEvenly',
              },
              isExpanded: true,
              decoration: const InputDecoration(labelText: '内容对齐'),
              items: const [
                DropdownMenuItem(
                  value: 'top',
                  child: Text(
                    '顶部对齐',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'center',
                  child: Text(
                    '居中对齐',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'spaceEvenly',
                  child: Text(
                    '均匀分布',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'bottom',
                  child: Text(
                    '底部对齐',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (v) => workspace.updateWidget(
                id,
                options: {'alignment': v ?? 'spaceEvenly'},
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示详细数据'),
              subtitle: const Text('显示 Token、TPM、统计窗口或额度重置时间。'),
              value: w.options['showDetails'] != false,
              onChanged: (v) =>
                  workspace.updateWidget(id, options: {'showDetails': v}),
            ),
          ],
        ]),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _inspectorFields([
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('move-$id'),
            isExpanded: true,
            decoration: const InputDecoration(labelText: '移到其他页面'),
            items: [
              for (final p in workspace.pages.where(
                (p) => p.id != workspace.activePage.id,
              ))
                DropdownMenuItem(
                  value: p.id,
                  child: Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) {
                final ok = workspace.moveWidgetToPage(id, v);
                _result(ok);
                if (ok) _closePanel();
              }
            },
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () {
              workspace.removeWidget(id);
              _closePanel();
            },
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除组件'),
          ),
        ], gap: 12),
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final columns = !desktopEditor && orientation == LayoutOrientation.wide
            ? math.max(1, (box.maxWidth / 260).floor()).clamp(1, 3)
            : 1;
        final columnWidth = (box.maxWidth - 24 - (columns - 1) * 16) / columns;
        return SingleChildScrollView(
          key: PageStorageKey('widget-inspector-$id'),
          primary: false,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final group in groups)
                SizedBox(width: columnWidth, child: group),
            ],
          ),
        );
      },
    );
  }

  Widget _placementControls(LayoutWidget w) {
    final r = w.placementFor(orientation);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '位置与尺寸 · 网格',
            style: TextStyle(color: deskbarColors(context).muted, fontSize: 13),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, box) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final field in [
                  ('x', 'X', r.x),
                  ('y', 'Y', r.y),
                  ('w', '宽', r.w),
                  ('h', '高', r.h),
                ])
                  SizedBox(
                    width: (box.maxWidth - 8) / 2,
                    child: _DesktopNumberField(
                      key: ValueKey(
                        'placement-${w.id}-${orientation.name}-${field.$1}',
                      ),
                      label: field.$2,
                      value: field.$3.toDouble(),
                      min: field.$1 == 'x' || field.$1 == 'y' ? 0 : 1,
                      max:
                          (field.$1 == 'x' || field.$1 == 'w'
                                  ? orientation.columns
                                  : orientation.rows)
                              .toDouble(),
                      onChanged: (value) {
                        final current = workspace
                            .findWidget(w.id)!
                            .placementFor(orientation);
                        _result(
                          workspace.setPlacement(
                            w.id,
                            orientation,
                            switch (field.$1) {
                              'x' => current.copyWith(x: value.round()),
                              'y' => current.copyWith(y: value.round()),
                              'w' => current.copyWith(w: value.round()),
                              _ => current.copyWith(h: value.round()),
                            },
                            displace: true,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bindingControls(LayoutWidget w) {
    final data = widget.connection.data;
    final source = w.type == 'sessions'
        ? 'codex.sessions'
        : w.type == 'shortcuts'
        ? 'host.shortcuts'
        : w.options['content'] == 'api'
        ? 'sub2api.usage'
        : 'codex.quota';
    final authorized =
        data != null &&
        (source == 'host.shortcuts'
            ? data.shortcuts.isNotEmpty
            : data.source(source) != null);
    final currentHost = w.binding['hostId'] as String?;
    final valid =
        authorized &&
        (currentHost == null ||
            currentHost == '' ||
            currentHost == data.hostId);
    final resources = <String, String>{
      if (w.type == 'shortcuts' && data != null)
        for (final s in data.shortcuts) s.id: s.name,
      if (w.type == 'usage' && data != null && source == 'codex.quota')
        for (final q in data.quotas) q.id: q.label,
      if (w.type == 'usage' && data != null && source == 'sub2api.usage')
        for (final u in data.apiUsage) u.id: u.label,
    };
    final selectedResource = w.binding['resourceId'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('binding-${w.id}-$source-$currentHost'),
          initialValue: valid ? source : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '已授权来源'),
          hint: Text(
            currentHost != null && !valid ? '原来源不可用，请重新选择' : '请在电脑端开启共享',
          ),
          items: [
            if (authorized)
              DropdownMenuItem(
                value: source,
                child: Text(
                  '${widget.connection.hostName ?? '此电脑'} · ${source == 'sub2api.usage' ? 'API 用量' : widgetTypeName(w.type)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) {
            if (v != null && data != null) {
              workspace.updateWidget(
                w.id,
                binding: {'hostId': data.hostId, 'source': v},
              );
            }
          },
        ),
        const SizedBox(height: 12),
        if (w.type == 'sessions')
          KeyedSubtree(
            key: ValueKey('session-limit-${w.id}'),
            child: _slider(
              '最多显示会话数',
              sessionDisplayLimit(w.options).toDouble(),
              1,
              maximumSessionDisplayLimit.toDouble(),
              (v) => workspace.updateWidget(
                w.id,
                options: {'maxSessions': v.round()},
              ),
              suffix: ' 个',
            ),
          )
        else if (valid) ...[
          DropdownButtonFormField<String>(
            key: ValueKey('resource-${w.id}-$source-$selectedResource'),
            initialValue: selectedResource == null || selectedResource.isEmpty
                ? ''
                : selectedResource,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '显示范围'),
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('全部', maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (selectedResource != null &&
                  selectedResource.isNotEmpty &&
                  !resources.containsKey(selectedResource))
                DropdownMenuItem(
                  value: selectedResource,
                  enabled: false,
                  child: const Text(
                    '原资源不可用，请重新选择',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              for (final r in resources.entries)
                DropdownMenuItem(
                  value: r.key,
                  child: Text(
                    r.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => workspace.updateWidget(
              w.id,
              binding: {
                'hostId': data.hostId,
                'source': source,
                if (v != null && v.isNotEmpty) 'resourceId': v,
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _optionSlider(
    LayoutWidget w,
    String key,
    String label,
    double min,
    double max,
    double fallback,
  ) {
    final raw = (w.options[key] as num?)?.toDouble() ?? fallback;
    final value = raw.isFinite ? raw.clamp(min, max).toDouble() : min;
    return _slider(
      label,
      value,
      min,
      max,
      (v) => workspace.updateWidget(w.id, options: {key: v.roundToDouble()}),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    String suffix = ' dp',
    bool enabled = true,
  }) => desktopEditor
      ? Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _DesktopNumberField(
            label: label,
            value: value,
            min: min,
            max: max,
            suffix: suffix.trim(),
            onChanged: enabled ? onChanged : null,
          ),
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Text('$label · ${value.round()}$suffix'),
            Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: math.max(1, (max - min).round()),
              onChanged: enabled ? onChanged : null,
            ),
          ],
        );
}

/// Commit on Enter or blur, so a partially typed number never changes layout.
class _DesktopNumberField extends StatefulWidget {
  const _DesktopNumberField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.suffix = '',
  });
  final String label, suffix;
  final double value, min, max;
  final ValueChanged<double>? onChanged;
  @override
  State<_DesktopNumberField> createState() => _DesktopNumberFieldState();
}

class _DesktopNumberFieldState extends State<_DesktopNumberField> {
  late final controller = TextEditingController(
    text: widget.value.round().toString(),
  );
  final focus = FocusNode();
  @override
  void initState() {
    super.initState();
    focus.addListener(_blur);
  }

  void _blur() {
    if (!focus.hasFocus) _commit();
  }

  void _commit() {
    final value = double.tryParse(controller.text);
    if (value != null &&
        value.isFinite &&
        value >= widget.min &&
        value <= widget.max &&
        value != widget.value) {
      widget.onChanged?.call(value.roundToDouble());
    }
    // Also restore the actual value after invalid input or a rejected placement.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.text = widget.value.round().toString();
    });
  }

  void _step(int delta) {
    final current = widget.value.round();
    final next = (current + delta).clamp(
      widget.min.round(),
      widget.max.round(),
    );
    if (next == current || widget.onChanged == null) return;
    controller.value = TextEditingValue(
      text: '$next',
      selection: TextSelection.collapsed(offset: '$next'.length),
    );
    widget.onChanged!(next.toDouble());
  }

  @override
  void didUpdateWidget(covariant _DesktopNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !focus.hasFocus) {
      controller.text = widget.value.round().toString();
    }
  }

  @override
  void dispose() {
    focus.removeListener(_blur);
    focus.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canDecrease = widget.onChanged != null && widget.value > widget.min;
    final canIncrease = widget.onChanged != null && widget.value < widget.max;
    return TextField(
      controller: controller,
      focusNode: focus,
      enabled: widget.onChanged != null,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        suffixIconConstraints: const BoxConstraints(
          minWidth: 64,
          maxWidth: 108,
          minHeight: 40,
        ),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.suffix.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(widget.suffix),
              ),
            SizedBox(
              width: 28,
              height: 36,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _stepButton(
                    key: ValueKey('number-increment-${widget.label}'),
                    tooltip: canIncrease ? '增加 1' : '已是最大值',
                    onPressed: canIncrease ? () => _step(1) : null,
                    icon: Icons.keyboard_arrow_up,
                  ),
                  _stepButton(
                    key: ValueKey('number-decrement-${widget.label}'),
                    tooltip: canDecrease ? '减少 1' : '已是最小值',
                    onPressed: canDecrease ? () => _step(-1) : null,
                    icon: Icons.keyboard_arrow_down,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) => focus.unfocus(),
    );
  }

  Widget _stepButton({
    required Key key,
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: EdgeInsets.zero,
    ),
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 28, height: 17),
    iconSize: 18,
    icon: Icon(icon),
  );
}

/// Keep the same editor and focus while external undo/redo updates its value.
class _WidgetNameField extends StatefulWidget {
  const _WidgetNameField({
    super.key,
    required this.id,
    required this.value,
    required this.onChanged,
  });
  final String id, value;
  final ValueChanged<String> onChanged;
  @override
  State<_WidgetNameField> createState() => _WidgetNameFieldState();
}

class _WidgetNameFieldState extends State<_WidgetNameField> {
  late final TextEditingController controller = TextEditingController(
    text: widget.value,
  );
  @override
  void didUpdateWidget(covariant _WidgetNameField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (controller.text != widget.value) {
      final previous = controller.selection.extentOffset;
      controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(
          offset: previous < 0
              ? widget.value.length
              : math.min(previous, widget.value.length),
        ),
      );
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    key: ValueKey('title-${widget.id}'),
    controller: controller,
    decoration: const InputDecoration(labelText: '组件名称'),
    onChanged: widget.onChanged,
  );
}

class _PlacedWidget extends StatefulWidget {
  const _PlacedWidget({
    super.key,
    required this.widget,
    required this.orientation,
    required this.size,
    required this.workspace,
    required this.connection,
    required this.onError,
    required this.onSettings,
    required this.onEditRequested,
    required this.preview,
    required this.onPreview,
    this.exactPreview = false,
    this.editable = false,
    this.debugLayout = false,
  });
  final LayoutWidget widget;
  final LayoutOrientation orientation;
  final Size size;
  final LayoutWorkspace workspace;
  final Connection connection;
  final ValueChanged<String> onError;
  final VoidCallback onSettings;
  final VoidCallback onEditRequested;
  final bool exactPreview, debugLayout, editable;
  final GridPlacement? preview;
  final ValueChanged<Map<String, GridPlacement>?> onPreview;
  @override
  State<_PlacedWidget> createState() => _PlacedWidgetState();
}

enum _LayoutDrag { move, left, right, bottom, bottomLeft, bottomRight }

class _PlacedWidgetState extends State<_PlacedWidget> {
  GridPlacement? candidate, original;
  LayoutDocument? gestureDocument;
  Offset delta = Offset.zero;
  bool valid = true;
  bool get editing => widget.workspace.editing;

  void _start() {
    widget.onSettings();
    gestureDocument = widget.workspace.document;
    original = widget.widget.placementFor(widget.orientation);
    candidate = null;
    delta = Offset.zero;
    valid = true;
  }

  @override
  void didUpdateWidget(covariant _PlacedWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.size != widget.size ||
        oldWidget.orientation != widget.orientation ||
        !editing ||
        (gestureDocument != null &&
            !identical(gestureDocument, widget.workspace.document))) {
      original = candidate = null;
      gestureDocument = null;
      valid = true;
    }
  }

  void _update(DragUpdateDetails details, _LayoutDrag kind) {
    final r = original;
    if (r == null) return;
    delta += details.delta;
    final cols = widget.orientation.columns, rows = widget.orientation.rows;
    final cw = widget.size.width / cols, ch = widget.size.height / rows;
    final dx = (delta.dx / cw).round(), dy = (delta.dy / ch).round();
    final minW = math.min(cols, ((96 + 4) / cw).ceil());
    final minH = math.min(rows, ((48 + 4) / ch).ceil());
    var next = r;
    if (kind == _LayoutDrag.move) {
      next = r.copyWith(
        x: (r.x + dx).clamp(0, cols - r.w),
        y: (r.y + dy).clamp(0, rows - r.h),
      );
    } else {
      if (kind == _LayoutDrag.left || kind == _LayoutDrag.bottomLeft) {
        final right = r.x + r.w;
        final left = (r.x + dx).clamp(0, right - math.min(minW, right)).toInt();
        next = next.copyWith(x: left, w: right - left);
      }
      if (kind == _LayoutDrag.right || kind == _LayoutDrag.bottomRight) {
        next = next.copyWith(
          w: (r.w + dx).clamp(math.min(minW, cols - r.x), cols - r.x),
        );
      }
      if (kind == _LayoutDrag.bottom ||
          kind == _LayoutDrag.bottomLeft ||
          kind == _LayoutDrag.bottomRight) {
        next = next.copyWith(
          h: (r.h + dy).clamp(math.min(minH, rows - r.y), rows - r.y),
        );
      }
    }
    if (next == candidate) return;
    final preview = widget.workspace.previewPlacement(
      widget.widget.id,
      widget.orientation,
      next,
    );
    setState(() {
      candidate = next;
      valid = preview != null;
    });
    widget.onPreview(preview);
  }

  void _end() {
    final r = candidate;
    if (r != null && original != null) {
      if (valid) {
        widget.workspace.setPlacement(
          widget.widget.id,
          widget.orientation,
          r,
          displace: true,
        );
      } else {
        widget.onError('没有足够空间，已保留原布局。请缩小组件或调整位置。');
      }
    }
    _cancel();
  }

  void _cancel() {
    setState(() {
      original = candidate = null;
      gestureDocument = null;
      valid = true;
    });
    widget.onPreview(null);
  }

  Widget _dragArea(_LayoutDrag kind, Widget child, String label) => Semantics(
    label: label,
    child: MouseRegion(
      cursor: switch (kind) {
        _LayoutDrag.move => SystemMouseCursors.move,
        _LayoutDrag.left ||
        _LayoutDrag.right => SystemMouseCursors.resizeLeftRight,
        _LayoutDrag.bottom => SystemMouseCursors.resizeUpDown,
        _LayoutDrag.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
        _LayoutDrag.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
      },
      child: Listener(
        // Flutter may deliver onPanEnd for an accepted drag after a system
        // pointer cancellation. Clear the preview before the recognizer ends.
        onPointerCancel: (_) {
          if (original != null) _cancel();
        },
        child: GestureDetector(
          key: ValueKey('widget-${kind.name}-${widget.widget.id}'),
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onTap: kind == _LayoutDrag.move
              ? widget.onSettings
              : () => widget.workspace.selectWidget(widget.widget.id),
          onPanStart: (_) => _start(),
          onPanUpdate: (details) => _update(details, kind),
          onPanEnd: (_) => _end(),
          onPanCancel: _cancel,
          child: child,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = deskbarColors(context);
    final r =
        candidate ??
        widget.preview ??
        widget.widget.placementFor(widget.orientation);
    final cw = widget.size.width / widget.orientation.columns,
        ch = widget.size.height / widget.orientation.rows;
    const gap = 2.0;
    final selected =
        editing && widget.workspace.selectedWidgetId == widget.widget.id;
    final body = WorkbenchWidgetBody(
      connection: widget.connection,
      id: widget.widget.id,
      type: widget.widget.type,
      options: widget.widget.options,
      binding: widget.widget.binding,
      editing: widget.editable || widget.exactPreview,
      debugLayout: widget.debugLayout,
      onEditRequested: widget.onEditRequested,
    );
    return AnimatedPositioned(
      duration: original != null
          ? Duration.zero
          : const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      left: r.x * cw + gap / 2,
      top: r.y * ch + gap / 2,
      width: math.max(0, r.w * cw - gap),
      height: math.max(0, r.h * ch - gap),
      child: widget.editable
          ? Tooltip(
              message: '设置${widgetTypeName(widget.widget.type)}',
              child: DecoratedBox(
                key: ValueKey('widget-edit-frame-${widget.widget.id}'),
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: !valid
                        ? c.danger
                        : selected
                        ? c.focus
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _dragArea(
                      _LayoutDrag.move,
                      IgnorePointer(child: body),
                      '移动${widgetTypeName(widget.widget.type)}',
                    ),
                    if (selected) ...[
                      _resizeHandle(
                        _LayoutDrag.left,
                        left: 0,
                        top: 0,
                        bottom: 16,
                        width: 12,
                      ),
                      _resizeHandle(
                        _LayoutDrag.right,
                        right: 0,
                        top: 0,
                        bottom: 16,
                        width: 12,
                      ),
                      _resizeHandle(
                        _LayoutDrag.bottom,
                        left: 16,
                        right: 16,
                        bottom: 0,
                        height: 12,
                      ),
                      _resizeHandle(
                        _LayoutDrag.bottomLeft,
                        left: 0,
                        bottom: 0,
                        width: 16,
                        height: 16,
                      ),
                      _resizeHandle(
                        _LayoutDrag.bottomRight,
                        right: 0,
                        bottom: 0,
                        width: 16,
                        height: 16,
                      ),
                    ],
                  ],
                ),
              ),
            )
          : widget.exactPreview
          ? IgnorePointer(child: body)
          : body,
    );
  }

  Widget _resizeHandle(
    _LayoutDrag kind, {
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
  }) => Positioned(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    width: width,
    height: height,
    child: _dragArea(
      kind,
      Center(
        child: Container(
          width: kind == _LayoutDrag.bottom ? 24 : 4,
          height: kind == _LayoutDrag.left || kind == _LayoutDrag.right
              ? 24
              : 4,
          decoration: BoxDecoration(
            color: deskbarColors(context).focus,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
      '缩放${widgetTypeName(widget.widget.type)}',
    ),
  );
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.orientation, this.color);
  final LayoutOrientation orientation;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0; x <= orientation.columns; x += 4) {
      for (var y = 0; y <= orientation.rows; y += 4) {
        canvas.drawCircle(
          Offset(
            x * size.width / orientation.columns,
            y * size.height / orientation.rows,
          ),
          1,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.orientation != orientation || old.color != color;
}
