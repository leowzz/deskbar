import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'connection.dart';
import 'display_preferences.dart';
import 'layout_repository.dart';
import 'layout_workspace.dart';
import 'rawblock.dart';
import 'workbench_content.dart';

String widgetTypeName(String type) => switch (type) {
  'sessions' => '会话',
  'usage' => '用量',
  'shortcuts' => '快捷入口',
  _ => '未知组件',
};

class WorkbenchCanvas extends StatefulWidget {
  const WorkbenchCanvas({
    super.key,
    required this.connection,
    this.workspace,
    this.repository,
    this.displayPreferences,
    this.onEditingChanged,
    this.onConnectionSettings,
  });
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
  bool reportedEditing = false;
  Size viewport = Size.zero;
  bool bindingQueued = false;
  Timer? _persist;
  bool loading = true, saving = false, _syncing = false, readOnly = false;
  String? warning, _activeId;
  DateTime _lastWheel = DateTime.fromMillisecondsSinceEpoch(0);
  LayoutOrientation orientation = LayoutOrientation.portrait;
  int get _pageIndex =>
      workspace.pages.indexWhere((p) => p.id == workspace.activePage.id);
  @override
  void initState() {
    super.initState();
    workspace.addListener(_changed);
    display.addListener(_displayChanged);
    widget.connection.addListener(_connectionChanged);
    _activeId = workspace.activePage.id;
    if (widget.workspace != null) {
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
      warning = '未能读取布局，当前使用初始布局。完成编辑时可以重新保存。';
    }
    if (mounted) {
      setState(() => loading = false);
      _scheduleBinding();
    }
  }

  @override
  void dispose() {
    _persist?.cancel();
    workspace.removeListener(_changed);
    widget.connection.removeListener(_connectionChanged);
    if (widget.workspace == null) workspace.dispose();
    pages.dispose();
    display.removeListener(_displayChanged);
    if (widget.displayPreferences == null) display.dispose();
    super.dispose();
  }

  void _displayChanged() {
    if (mounted) setState(() {});
  }

  void _connectionChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleBinding();
  }

  void _scheduleBinding() {
    if (bindingQueued ||
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
            if (mounted) _toast('组件已绑定此电脑，但未能保存。请完成一次布局编辑以重新保存。');
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
    if (activeChanged && !workspace.editing && !readOnly && !loading) {
      _persist?.cancel();
      _persist = Timer(
        const Duration(milliseconds: 250),
        () => unawaited(_saveNavigation()),
      );
    }
  }

  Future<void> _saveNavigation() async {
    try {
      await repository.save(workspace.committed);
    } catch (_) {
      if (mounted) _toast('页面选择未保存，布局仍可使用。');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _result(bool success) {
    if (!success) _toast(workspace.error ?? '未能完成修改');
  }

  void _begin() {
    if (readOnly || loading || saving) {
      _toast(readOnly ? '请升级工作台后再编辑布局。' : '正在读取布局，请稍候。');
      return;
    }
    _persist?.cancel();
    workspace.beginEdit();
  }

  Future<void> _finish() async {
    if (saving) return;
    setState(() => saving = true);
    try {
      final savedDocument = _bindDocument(workspace.document);
      await repository.save(savedDocument);
      if (!mounted) return;
      workspace.replaceDocument(savedDocument);
      _toast('已保存所有页面');
    } catch (_) {
      _toast('布局未能保存，草稿仍保留。请重试。');
    } finally {
      if (mounted) setState(() => saving = false);
    }
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
  });
  void _openPanel(String name) => setState(() => panel = name);

  @override
  Widget build(BuildContext context) {
    final c = deskletColors(context);
    return PopScope(
      canPop: !workspace.editing && !display.immersive && !saving,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || saving) return;
        if (panel != null) {
          _closePanel();
        } else if (workspace.editing) {
          workspace.cancelEdit();
        } else if (display.immersive) {
          unawaited(display.setImmersive(false));
        }
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
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
            if (workspace.editing) _editToolbar(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  orientation =
                      MediaQuery.orientationOf(context) == Orientation.landscape
                      ? LayoutOrientation.wide
                      : LayoutOrientation.portrait;
                  final canvas = loading
                      ? const Center(child: CircularProgressIndicator())
                      : _canvas();
                  if (!workspace.editing || panel == null) return canvas;
                  final inspector = _editorPanel();
                  if (box.maxWidth > box.maxHeight) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: canvas),
                        SizedBox(
                          width: math.min(320, box.maxWidth * .44),
                          child: inspector,
                        ),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      Expanded(child: canvas),
                      SizedBox(height: box.maxHeight * .54, child: inspector),
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

  Widget _editToolbar() => Material(
    color: deskletColors(context).sidebar,
    child: SizedBox(
      height: 48,
      child: Row(
        children: [
          TextButton(
            onPressed: saving ? null : workspace.cancelEdit,
            child: const Text('取消'),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  PopupMenuButton<String>(
                    tooltip: '切换编辑页面',
                    enabled: !saving,
                    onSelected: _navigate,
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
                    onPressed: workspace.canUndo && !saving
                        ? workspace.undo
                        : null,
                    icon: const Icon(Icons.undo),
                  ),
                  IconButton(
                    tooltip: '重做',
                    onPressed: workspace.canRedo && !saving
                        ? workspace.redo
                        : null,
                    icon: const Icon(Icons.redo),
                  ),
                  IconButton(
                    tooltip: '添加组件',
                    onPressed: saving ? null : _addWidget,
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    tooltip: '显示的组件',
                    onPressed: saving ? null : _components,
                    icon: const Icon(Icons.layers_outlined),
                  ),
                  IconButton(
                    tooltip: '管理页面',
                    onPressed: saving ? null : _managePages,
                    icon: const Icon(Icons.tab_outlined),
                  ),
                  IconButton(
                    tooltip: '整理本页',
                    onPressed: saving
                        ? null
                        : () => _result(workspace.arrangePage(orientation)),
                    icon: const Icon(Icons.auto_awesome_mosaic_outlined),
                  ),
                  IconButton(
                    tooltip: '显示设置',
                    onPressed: saving ? null : () => _openPanel('display'),
                    icon: const Icon(Icons.settings_display_outlined),
                  ),
                ],
              ),
            ),
          ),
          FilledButton(
            onPressed: saving ? null : _finish,
            child: Text(saving ? '保存中…' : '完成'),
          ),
        ],
      ),
    ),
  );
  Widget _canvas() => LayoutBuilder(
    builder: (context, box) {
      viewport = box.biggest;
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
          child: AbsorbPointer(
            absorbing: saving,
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
        ),
      );
    },
  );
  Widget _page(LayoutPage page) {
    final visible = page.widgets.where((w) => w.visible).toList();
    return Padding(
      padding: EdgeInsets.all(workspace.editing ? 4 : 2),
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: ValueKey('page-edit-background-${page.id}'),
                behavior: HitTestBehavior.opaque,
                onLongPress: workspace.editing ? null : _begin,
                onTap: workspace.editing
                    ? () => workspace.selectWidget(null)
                    : null,
                child: workspace.editing
                    ? CustomPaint(
                        painter: _GridPainter(
                          orientation,
                          deskletColors(context).line,
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
      _ => '显示设置',
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
      _ => _displayBody(),
    };
    return Material(
      color: deskletColors(context).surface,
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭设置',
                  onPressed: _closePanel,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: AbsorbPointer(
              absorbing: saving,
              child: KeyedSubtree(
                key: ValueKey('editor-panel-$panel-${inspectedId ?? ''}'),
                child: body,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _displayBody() => ListenableBuilder(
    listenable: display,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(8),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('沉浸显示'),
          value: display.immersive,
          onChanged: display.setImmersive,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('锁定旋转'),
          subtitle: const Text('保持当前方向'),
          value: display.rotationLocked,
          onChanged: display.setRotationLocked,
        ),
        if (display.error != null)
          Text(
            display.error!,
            style: TextStyle(color: deskletColors(context).warning),
          ),
        if (widget.onConnectionSettings != null)
          TextButton.icon(
            onPressed: widget.onConnectionSettings,
            icon: const Icon(Icons.computer_outlined),
            label: const Text('连接与外观设置'),
          ),
      ],
    ),
  );

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
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () async {
            final name = await _askName('新建空白页', '新页面');
            if (name != null && mounted) workspace.addPage(name: name);
          },
          icon: const Icon(Icons.add),
          label: const Text('新建页面'),
        ),
      ),
      Expanded(
        child: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          onReorderItem: (oldIndex, newIndex) => _result(
            workspace.movePage(workspace.pages[oldIndex].id, newIndex),
          ),
          itemCount: workspace.pages.length,
          itemBuilder: (context, index) {
            final p = workspace.pages[index];
            return ListTile(
              key: ValueKey(p.id),
              contentPadding: EdgeInsets.zero,
              leading: ReorderableDragStartListener(
                index: index,
                child: const SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(Icons.drag_handle),
                ),
              ),
              title: Text(p.name),
              onTap: () => _navigate(p.id),
              trailing: PopupMenuButton<String>(
                tooltip: '页面操作 ${p.name}',
                onSelected: (action) async {
                  if (action == 'rename') {
                    final name = await _askName('重命名页面', p.name);
                    if (name != null && mounted) {
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
          contentPadding: EdgeInsets.zero,
          leading: Checkbox(
            value: w.visible,
            onChanged: (v) =>
                _result(workspace.setWidgetVisible(w.id, v ?? false)),
          ),
          title: Text(w.title.isEmpty ? widgetTypeName(w.type) : w.title),
          onTap: () => _inspect(w.id),
          trailing: IconButton(
            tooltip: '设置组件',
            onPressed: () => _inspect(w.id),
            icon: const Icon(Icons.tune),
          ),
        ),
      if (workspace.activePage.widgets.isEmpty)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('新页面从空白开始，可以重复添加同类组件。'),
        ),
      TextButton.icon(
        onPressed: _addWidget,
        icon: const Icon(Icons.add),
        label: const Text('添加组件'),
      ),
    ],
  );
  Future<void> _inspect(String id) async {
    workspace.selectWidget(id);
    setState(() {
      panel = 'widget';
      inspectedId = id;
    });
  }

  Widget _widgetInspector() {
    final id = inspectedId;
    final w = workspace.findWidget(id);
    if (id == null || w == null) {
      return const Center(child: Text('组件已移除，可撤销恢复。'));
    }
    return SingleChildScrollView(
      key: PageStorageKey('widget-inspector-$id'),
      primary: false,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _WidgetNameField(
            key: ValueKey('name-editor-$id'),
            id: id,
            value: w.title,
            onChanged: (v) => workspace.updateWidget(id, title: v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('显示组件'),
            value: w.visible,
            onChanged: (v) => _result(workspace.setWidgetVisible(id, v)),
          ),
          _bindingControls(w),
          const SizedBox(height: 16),
          Text(
            orientation == LayoutOrientation.wide ? '横屏摆放' : '竖屏摆放',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Text('拖动组件把手移动，拖动缩放把手调整大小。'),
          for (final field in ['w', 'h', 'x', 'y']) _placementSlider(w, field),
          const Divider(),
          if (w.type == 'sessions') ...[
            _optionSlider(w, 'itemWidth', '卡片目标宽度', 120, 600, 280),
            _optionSlider(w, 'itemHeight', '卡片目标高度', 64, 400, 96),
            _optionSlider(w, 'gap', '卡片间距', 0, 40, 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
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
              decoration: const InputDecoration(labelText: '会话信息'),
              items: const [
                DropdownMenuItem(value: 'normal', child: Text('标准')),
                DropdownMenuItem(value: 'compact', child: Text('精简')),
              ],
              onChanged: (v) =>
                  workspace.updateWidget(id, options: {'density': v}),
            ),
          ],
          if (w.type == 'shortcuts') ...[
            _optionSlider(w, 'iconSize', '图标尺寸', 24, 200, 56),
            _optionSlider(w, 'gapX', '横向间距', 0, 64, 16),
            _optionSlider(w, 'gapY', '纵向间距', 0, 64, 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示名称'),
              value: w.options['labels'] != false,
              onChanged: (v) =>
                  workspace.updateWidget(id, options: {'labels': v}),
            ),
          ],
          if (w.type == 'usage')
            DropdownButtonFormField<String>(
              key: ValueKey('content-$id-${w.options['content']}'),
              initialValue: w.options['content'] == 'api' ? 'api' : 'quota',
              decoration: const InputDecoration(labelText: '用量内容'),
              items: const [
                DropdownMenuItem(value: 'quota', child: Text('Codex 额度')),
                DropdownMenuItem(value: 'api', child: Text('API 用量')),
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
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('move-$id'),
            decoration: const InputDecoration(labelText: '移到其他页面'),
            items: [
              for (final p in workspace.pages.where(
                (p) => p.id != workspace.activePage.id,
              ))
                DropdownMenuItem(value: p.id, child: Text(p.name)),
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
      if (w.type == 'sessions' && data != null)
        for (final s in data.sessions) s.id: s.title,
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
        if (valid) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('resource-${w.id}-$source-$selectedResource'),
            initialValue: selectedResource == null || selectedResource.isEmpty
                ? ''
                : selectedResource,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '显示范围'),
            items: [
              const DropdownMenuItem(value: '', child: Text('全部')),
              if (selectedResource != null &&
                  selectedResource.isNotEmpty &&
                  !resources.containsKey(selectedResource))
                DropdownMenuItem(
                  value: selectedResource,
                  enabled: false,
                  child: const Text('原资源不可用，请重新选择'),
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

  Widget _placementSlider(LayoutWidget w, String field) {
    final r = w.placementFor(orientation);
    final max = field == 'w'
        ? orientation.columns - r.x
        : field == 'h'
        ? orientation.rows - r.y
        : field == 'x'
        ? orientation.columns - r.w
        : orientation.rows - r.h;
    final rawMin = field == 'w' && viewport.width > 0
        ? ((math.min(viewport.width, w.type == 'sessions' ? 180.0 : 110.0) +
                      8) /
                  (viewport.width / orientation.columns))
              .ceil()
        : field == 'h' && viewport.height > 0
        ? ((math.min(viewport.height, 112.0) + 8) /
                  (viewport.height / orientation.rows))
              .ceil()
        : 0;
    final minimum = field == 'w' || field == 'h'
        ? math.min(math.max(1, max), math.max(1, rawMin))
        : 0;
    final value = switch (field) {
      'w' => r.w,
      'h' => r.h,
      'x' => r.x,
      _ => r.y,
    };
    return _slider(
      switch (field) {
        'w' => '区域宽度',
        'h' => '区域高度',
        'x' => '左侧位置',
        _ => '顶部位置',
      },
      value.toDouble(),
      minimum.toDouble(),
      math.max(minimum + 1, max).toDouble(),
      (v) {
        final n = v.round().clamp(minimum, max);
        _result(
          workspace.setPlacement(
            w.id,
            orientation,
            r.copyWith(
              w: field == 'w' ? n : null,
              h: field == 'h' ? n : null,
              x: field == 'x' ? n : null,
              y: field == 'y' ? n : null,
            ),
          ),
        );
      },
      suffix: ' 格',
      enabled: max > minimum,
    );
  }

  Widget _optionSlider(
    LayoutWidget w,
    String key,
    String label,
    double min,
    double max,
    double fallback,
  ) => _slider(
    label,
    (w.options[key] as num?)?.toDouble() ?? fallback,
    min,
    max,
    (v) => workspace.updateWidget(w.id, options: {key: v.roundToDouble()}),
  );
  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    String suffix = ' dp',
    bool enabled = true,
  }) => Column(
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
  });
  final LayoutWidget widget;
  final LayoutOrientation orientation;
  final Size size;
  final LayoutWorkspace workspace;
  final Connection connection;
  final ValueChanged<String> onError;
  final VoidCallback onSettings;
  final VoidCallback onEditRequested;
  @override
  State<_PlacedWidget> createState() => _PlacedWidgetState();
}

class _PlacedWidgetState extends State<_PlacedWidget> {
  GridPlacement? candidate, original;
  Offset delta = Offset.zero;
  bool valid = true;
  bool get editing => widget.workspace.editing;
  void _start() {
    original = widget.widget.placementFor(widget.orientation);
    delta = Offset.zero;
    widget.workspace.selectWidget(widget.widget.id);
  }

  void _update(DragUpdateDetails d, bool resize) {
    final r = original;
    if (r == null) return;
    delta += d.delta;
    final dx = (delta.dx / (widget.size.width / widget.orientation.columns))
        .round();
    final dy = (delta.dy / (widget.size.height / widget.orientation.rows))
        .round();
    final cols = widget.orientation.columns, rows = widget.orientation.rows;
    GridPlacement next;
    if (resize) {
      final minW = math.min(
        cols,
        math.max(
          1,
          (math.min(
                    widget.size.width,
                    widget.widget.type == 'sessions' ? 180.0 : 100.0,
                  ) /
                  (widget.size.width / cols))
              .ceil(),
        ),
      );
      final minH = math.min(
        rows,
        math.max(
          1,
          (math.min(widget.size.height, 112.0) / (widget.size.height / rows))
              .ceil(),
        ),
      );
      next = r.copyWith(
        w: (r.w + dx).clamp(math.min(minW, cols - r.x), cols - r.x),
        h: (r.h + dy).clamp(math.min(minH, rows - r.y), rows - r.y),
      );
    } else {
      next = r.copyWith(
        x: (r.x + dx).clamp(0, cols - r.w),
        y: (r.y + dy).clamp(0, rows - r.h),
      );
    }
    setState(() {
      candidate = next;
      valid = widget.workspace.canPlace(
        widget.widget.id,
        widget.orientation,
        next,
      );
    });
  }

  void _end() {
    final r = candidate;
    if (r != null) {
      if (valid) {
        widget.workspace.setPlacement(widget.widget.id, widget.orientation, r);
      } else {
        widget.onError('位置与其他组件重叠，已回到原位。');
      }
    }
    setState(() {
      candidate = null;
      original = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = deskletColors(context);
    final r = candidate ?? widget.widget.placementFor(widget.orientation);
    final cw = widget.size.width / widget.orientation.columns,
        ch = widget.size.height / widget.orientation.rows;
    final gap = editing ? 4.0 : 2.0;
    final selected =
        editing && widget.workspace.selectedWidgetId == widget.widget.id;
    final body = WorkbenchWidgetBody(
      connection: widget.connection,
      id: widget.widget.id,
      type: widget.widget.type,
      options: widget.widget.options,
      binding: widget.widget.binding,
      editing: editing,
      onEditRequested: widget.onEditRequested,
    );
    return Positioned(
      left: r.x * cw + gap / 2,
      top: r.y * ch + gap / 2,
      width: math.max(0, r.w * cw - gap),
      height: math.max(0, r.h * ch - gap),
      child: editing
          ? GestureDetector(
              onTap: () => widget.workspace.selectWidget(widget.widget.id),
              child: DecoratedBox(
                key: ValueKey('widget-edit-frame-${widget.widget.id}'),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: !valid
                        ? c.danger
                        : selected
                        ? c.focus
                        : c.line,
                    width: selected || !valid ? 2 : 1,
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final name = widgetTypeName(widget.widget.type);
                    if (box.maxWidth < 96 || box.maxHeight < 48) {
                      return Tooltip(
                        message: '设置$name',
                        child: InkWell(
                          onTap: widget.onSettings,
                          child: Center(
                            child: Icon(
                              Icons.tune,
                              size: math.max(
                                1,
                                math.min(
                                  18,
                                  math.min(box.maxWidth, box.maxHeight),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    final header = Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onSettings,
                            onPanStart: (_) => _start(),
                            onPanUpdate: (d) => _update(d, false),
                            onPanEnd: (_) => _end(),
                            onPanCancel: () => setState(() => candidate = null),
                            child: Tooltip(
                              message: '设置$name',
                              child: SizedBox(
                                height: 48,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.drag_indicator,
                                        size: 18,
                                      ),
                                      if (box.maxWidth >= 156)
                                        Expanded(
                                          child: Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (box.maxWidth >= 192)
                          IconButton(
                            tooltip: '设置$name',
                            onPressed: widget.onSettings,
                            icon: const Icon(Icons.tune, size: 18),
                          ),
                        Semantics(
                          label: '拖动缩放$name',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (_) => _start(),
                            onPanUpdate: (d) => _update(d, true),
                            onPanEnd: (_) => _end(),
                            onPanCancel: () => setState(() => candidate = null),
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: Icon(
                                Icons.open_in_full,
                                size: 18,
                                color: c.selectedText,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(height: 48, child: header),
                        if (box.maxHeight > 48)
                          Expanded(child: IgnorePointer(child: body)),
                      ],
                    );
                  },
                ),
              ),
            )
          : body,
    );
  }
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
    for (var x = 0; x <= orientation.columns; x++) {
      for (var y = 0; y <= orientation.rows; y++) {
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
