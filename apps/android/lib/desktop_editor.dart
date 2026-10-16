// Desktop-only Flutter entrypoint. The React shell owns authenticated IPC.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'connection.dart';
import 'layout_repository.dart';
import 'layout_workspace.dart';
import 'rawblock.dart';
import 'workbench_canvas.dart';
import 'workbench_data.dart';

@JS('registerDeskbarEditor')
external void registerEditor(JSFunction callback);
@JS('sendDeskbarEditor')
external void sendEditor(JSString message);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DesktopEditor());
}

class DesktopEditor extends StatefulWidget {
  const DesktopEditor({super.key});
  @override
  State<DesktopEditor> createState() => _DesktopEditorState();
}

class _DesktopEditorState extends State<DesktopEditor> {
  final connection = Connection();
  final workspace = LayoutWorkspace();
  late final repository = _DesktopRepository(_save);
  final Map<int, Completer<void>> requests = {};
  int requestId = 0, revision = 0;
  bool ready = false, debug = false, dark = false;
  bool lastEditing = false, previewFit = true;
  LayoutOrientation previewOrientation = LayoutOrientation.wide;
  bool orientationChosen = false;
  double deviceWidth = 1280, deviceHeight = 720, textScale = 1;
  String? error;
  Map<String, dynamic>? latest;

  double get previewWidth => previewOrientation == LayoutOrientation.wide
      ? _deviceLongSide
      : _deviceShortSide;
  double get previewHeight => previewOrientation == LayoutOrientation.wide
      ? _deviceShortSide
      : _deviceLongSide;
  double get _deviceLongSide =>
      deviceWidth >= deviceHeight ? deviceWidth : deviceHeight;
  double get _deviceShortSide =>
      deviceWidth >= deviceHeight ? deviceHeight : deviceWidth;

  @override
  void initState() {
    super.initState();
    workspace.addListener(_changed);
    registerEditor(((JSString value) => _receive(value.toDart)).toJS);
    sendEditor(jsonEncode({'type': 'ready'}).toJS);
  }

  void _changed() {
    if (lastEditing != workspace.editing) {
      lastEditing = workspace.editing;
      sendEditor(jsonEncode({'type': 'editing', 'value': lastEditing}).toJS);
      // Cancel may expose a newer externally saved document.
      if (!lastEditing && latest != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !workspace.editing) _apply(latest!);
        });
      }
    }
    if (mounted) setState(() {});
  }

  void _receive(String text) {
    try {
      final message = jsonDecode(text) as Map<String, dynamic>;
      if (message['type'] == 'state') {
        latest = message;
        _apply(message);
      } else if (message['type'] == 'saved') {
        final pending = requests.remove(message['requestId']);
        if (pending == null) return;
        if (message['error'] != null) {
          setState(() => error = message['error'] as String);
          pending.completeError(StateError(error!));
        } else {
          revision = message['revision'] as int;
          // A polling response from before this save must not undo it.
          latest = null;
          pending.complete();
        }
      }
    } catch (_) {
      setState(() => error = '未能读取工作台，请重新打开编辑器。');
    }
  }

  void _apply(Map<String, dynamic> message) {
    final snapshot = message['snapshot'] as Map<String, dynamic>;
    final data = WorkbenchData(snapshot);
    final display = message['display'] as Map<String, dynamic>?;
    final online =
        display != null &&
        DateTime.now().millisecondsSinceEpoch / 1000 -
                (display['seen_at'] as num) <
            15;
    connection.data = data;
    connection.hostName = snapshot['name'] as String;
    connection.phase = online
        ? ConnectionPhase.online
        : ConnectionPhase.offline;
    if (!workspace.editing && (!ready || data.layoutRevision > revision)) {
      revision = data.layoutRevision;
      workspace.replaceDocument(data.layout);
    }
    if (!workspace.editing && display != null) {
      final page = display['page_id'] as String;
      if (workspace.pages.any((p) => p.id == page)) {
        workspace.setActivePage(page);
      }
    }
    if (display != null) {
      final width = display['width'];
      final height = display['height'];
      if (width is num && height is num && width > 0 && height > 0) {
        deviceWidth = width.toDouble();
        deviceHeight = height.toDouble();
        if (!orientationChosen) {
          previewOrientation = deviceWidth >= deviceHeight
              ? LayoutOrientation.wide
              : LayoutOrientation.portrait;
        }
      }
      final scale = display['text_scale'];
      textScale = scale is num && scale > 0 ? scale.toDouble() : 1;
      dark = display['dark'] == true;
    }
    // Only authorized public snapshot fields cross the iframe boundary.
    connection.notifyListeners();
    setState(() => ready = true);
  }

  Future<void> _save(LayoutDocument document) async {
    final id = ++requestId;
    final pending = Completer<void>();
    requests[id] = pending;
    setState(() => error = null);
    sendEditor(
      jsonEncode({
        'type': 'save',
        'requestId': id,
        'expectedRevision': revision,
        'layout': document.toJson(),
      }).toJS,
    );
    try {
      await pending.future.timeout(const Duration(seconds: 20));
    } finally {
      requests.remove(id);
    }
  }

  @override
  void dispose() {
    workspace.removeListener(_changed);
    workspace.dispose();
    connection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _editorTheme(Brightness.light),
    darkTheme: _editorTheme(Brightness.dark),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    home: Scaffold(
      body: !ready
          ? const Center(child: Text('正在读取设备工作台…'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Wrap(
                    alignment: WrapAlignment.start,
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<LayoutOrientation>(
                        value: previewOrientation,
                        items: const [
                          DropdownMenuItem(
                            value: LayoutOrientation.wide,
                            child: Text('横屏'),
                          ),
                          DropdownMenuItem(
                            value: LayoutOrientation.portrait,
                            child: Text('竖屏'),
                          ),
                        ],
                        onChanged: (v) => setState(() {
                          if (v == null) return;
                          previewOrientation = v;
                          orientationChosen = true;
                        }),
                      ),
                      FilterChip(
                        label: const Text('原始尺寸'),
                        selected: !previewFit,
                        onSelected: (v) => setState(() => previewFit = !v),
                      ),
                      FilterChip(
                        label: const Text('布局调试'),
                        selected: debug,
                        onSelected: (v) => setState(() => debug = v),
                      ),
                    ],
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(error!),
                  ),
                Expanded(
                  child: WorkbenchCanvas(
                    connection: connection,
                    workspace: workspace,
                    repository: repository,
                    allowEditing: true,
                    previewSize: Size(previewWidth, previewHeight),
                    previewFit: previewFit,
                    previewTextScale: textScale,
                    debugLayout: debug,
                  ),
                ),
              ],
            ),
    ),
  );

  ThemeData _editorTheme(Brightness brightness) {
    final theme = rawBlockTheme(brightness);
    return theme.copyWith(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      filledButtonTheme: FilledButtonThemeData(
        style: theme.filledButtonTheme.style?.copyWith(
          // Compact density subtracts 8 px; retain a 36 px click target.
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: theme.textButtonTheme.style?.copyWith(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        ),
      ),
    );
  }
}

class _DesktopRepository extends LayoutRepository {
  _DesktopRepository(this.persist);
  final Future<void> Function(LayoutDocument) persist;
  @override
  Future<void> save(LayoutDocument document) => persist(document);
}
