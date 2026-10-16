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
  bool ready = false, debug = false, followDevice = true, dark = false;
  bool lastEditing = false, previewFit = true;
  double width = 1280, height = 720, textScale = 1;
  String? error;
  Timer? clock;
  Map<String, dynamic>? latest;

  @override
  void initState() {
    super.initState();
    workspace.addListener(_changed);
    registerEditor(((JSString value) => _receive(value.toDart)).toJS);
    sendEditor(jsonEncode({'type': 'ready'}).toJS);
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
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
    if (!workspace.editing && followDevice && display != null) {
      final page = display['page_id'] as String;
      if (workspace.pages.any((p) => p.id == page)) {
        workspace.setActivePage(page);
      }
    }
    if (followDevice && display != null) {
      width = (display['width'] as num).toDouble();
      height = (display['height'] as num).toDouble();
      textScale = (display['text_scale'] as num).toDouble();
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
    clock?.cancel();
    workspace.removeListener(_changed);
    workspace.dispose();
    connection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: rawBlockTheme().copyWith(platform: TargetPlatform.android),
    darkTheme: rawBlockTheme(
      Brightness.dark,
    ).copyWith(platform: TargetPlatform.android),
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
                      DropdownButton<String>(
                        value: followDevice ? 'device' : 'custom',
                        items: const [
                          DropdownMenuItem(
                            value: 'device',
                            child: Text('跟随设备'),
                          ),
                          DropdownMenuItem(
                            value: 'wide',
                            child: Text('横屏 1280 × 720'),
                          ),
                          DropdownMenuItem(
                            value: 'portrait',
                            child: Text('竖屏 400 × 800'),
                          ),
                          DropdownMenuItem(
                            value: 'custom',
                            child: Text('自定义尺寸'),
                          ),
                        ],
                        onChanged: (v) => setState(() {
                          followDevice = v == 'device';
                          if (v == 'wide') {
                            width = 1280;
                            height = 720;
                          }
                          if (v == 'portrait') {
                            width = 400;
                            height = 800;
                          }
                          if (followDevice && latest != null) _apply(latest!);
                        }),
                      ),
                      if (followDevice)
                        Text(
                          '${width.round()} × ${height.round()} dp · 字号 ${textScale.toStringAsFixed(2)}×',
                        )
                      else ...[
                        _dimension(
                          '宽',
                          width,
                          (v) => setState(() => width = v),
                        ),
                        _dimension(
                          '高',
                          height,
                          (v) => setState(() => height = v),
                        ),
                        IconButton(
                          tooltip: '旋转预览',
                          onPressed: () => setState(() {
                            final old = width;
                            width = height;
                            height = old;
                          }),
                          icon: const Icon(Icons.screen_rotation),
                        ),
                        IconButton(
                          tooltip: '切换预览主题',
                          onPressed: () => setState(() => dark = !dark),
                          icon: Icon(
                            dark
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined,
                          ),
                        ),
                      ],
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
                    previewSize: Size(width, height),
                    previewFit: previewFit,
                    previewTextScale: textScale,
                    debugLayout: debug,
                  ),
                ),
              ],
            ),
    ),
  );

  Widget _dimension(
    String label,
    double value,
    ValueChanged<double> onChanged,
  ) => SizedBox(
    width: 100,
    child: TextFormField(
      key: ValueKey('$label-$value'),
      initialValue: value.round().toString(),
      decoration: InputDecoration(labelText: '$label (dp)'),
      keyboardType: TextInputType.number,
      onFieldSubmitted: (v) {
        final number = double.tryParse(v);
        if (number != null && number >= 200 && number <= 8192) {
          onChanged(number);
        }
      },
    ),
  );
}

class _DesktopRepository extends LayoutRepository {
  _DesktopRepository(this.persist);
  final Future<void> Function(LayoutDocument) persist;
  @override
  Future<void> save(LayoutDocument document) => persist(document);
}
