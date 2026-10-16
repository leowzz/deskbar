import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'connection.dart';
import 'workbench_canvas.dart';
import 'package:flutter/services.dart';
import 'rawblock.dart';

void main() => runApp(const DeskletApp());

class DeskletApp extends StatefulWidget {
  const DeskletApp({super.key});
  @override
  State<DeskletApp> createState() => _DeskletAppState();
}

class _DeskletAppState extends State<DeskletApp> {
  static const preferences = MethodChannel('app.desklet/layout');
  ThemeMode mode = ThemeMode.light;
  bool changedTheme = false;
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  @override
  void initState() {
    super.initState();
    unawaited(_restoreTheme());
  }

  Future<void> _restoreTheme() async {
    try {
      final saved = await preferences.invokeMethod<String>('loadTheme');
      if (mounted && !changedTheme) {
        setState(
          () => mode = saved == 'dark' ? ThemeMode.dark : ThemeMode.light,
        );
      }
    } catch (_) {
      /* Unsupported test platforms use the documented light default. */
    }
  }

  Future<void> _theme() async {
    changedTheme = true;
    final next = mode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    setState(() => mode = next);
    try {
      await preferences.invokeMethod<void>('saveTheme', {
        'theme': next == ThemeMode.dark ? 'dark' : 'light',
      });
    } catch (_) {
      if (mounted) {
        messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('主题已切换，但未能保存。重启后会恢复原设置。')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Desklet 工作台',
    scaffoldMessengerKey: messengerKey,
    debugShowCheckedModeBanner: false,
    theme: rawBlockTheme(),
    darkTheme: rawBlockTheme(Brightness.dark),
    themeMode: mode,
    builder: (context, child) {
      final c = deskletColors(context);
      final icons = Theme.of(context).brightness == Brightness.dark
          ? Brightness.light
          : Brightness.dark;
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: c.sidebar,
          statusBarIconBrightness: icons,
          systemNavigationBarColor: c.canvas,
          systemNavigationBarIconBrightness: icons,
        ),
        child: child ?? const SizedBox(),
      );
    },
    home: Workbench(onTheme: _theme),
  );
}

class Workbench extends StatefulWidget {
  const Workbench({super.key, this.onTheme});
  final VoidCallback? onTheme;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> with WidgetsBindingObserver {
  final connection = Connection();
  bool pasteOpen = false;
  bool immersive = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(connection.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Camera and system dialogs can briefly make the Activity inactive.
    if (state == AppLifecycleState.resumed) {
      unawaited(connection.setActive(true));
    }
    if (state == AppLifecycleState.paused) {
      unawaited(connection.setActive(false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    connection.dispose();
    super.dispose();
  }

  Future<void> paste([String? initial]) async {
    if (pasteOpen) return;
    pasteOpen = true;
    final invitation = TextEditingController(text: initial);
    final name = TextEditingController(text: 'Android 工作台');
    final value = await showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('粘贴连接邀请'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('在电脑上的 Desklet 连接助手点击「连接设备」，复制完整邀请。'),
                const SizedBox(height: 20),
                TextField(
                  controller: invitation,
                  style: rawMono,
                  decoration: const InputDecoration(
                    labelText: '连接邀请',
                    hintText: 'desklet://pair…',
                  ),
                  minLines: 2,
                  maxLines: 4,
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: name,
                  style: rawMono,
                  maxLength: 64,
                  decoration: const InputDecoration(labelText: '这台设备的名称'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (invitation.text.trim().isNotEmpty &&
                  name.text.trim().isNotEmpty) {
                Navigator.pop(context, (
                  invitation.text.trim(),
                  name.text.trim(),
                ));
              }
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
    // Dispose after route transition so fields no longer reference controllers.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    invitation.dispose();
    name.dispose();
    pasteOpen = false;
    if (value != null && mounted) await connection.pair(value.$1, value.$2);
  }

  Future<void> scan() async {
    final invitation = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (invitation != null && mounted) await paste(invitation);
  }

  Future<void> forget() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('断开这台电脑？'),
        content: const Text('此设备会清除连接信息。再次使用需要重新配对。你也可以在电脑上移除这台设备。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: rawButton(destructive: true),
            child: const Text('断开连接'),
          ),
        ],
      ),
    );
    if (confirmed == true) await connection.forget();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: connection,
    builder: (context, _) {
      final paired = connection.hostName != null;
      final online = connection.phase == ConnectionPhase.online;
      final text = Theme.of(context).textTheme;
      final c = deskletColors(context);
      final compact = MediaQuery.sizeOf(context).height < 400;
      return Scaffold(
        appBar: immersive
            ? null
            : AppBar(
                title: Text(
                  compact && paired ? connection.hostName! : 'Desklet 工作台',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: compact ? 16 : 22),
                ),
                toolbarHeight: compact ? 48 : 56,
                actions: [
                  if (compact && paired)
                    TextButton(onPressed: forget, child: const Text('断开电脑')),
                  IconButton(
                    tooltip: Theme.of(context).brightness == Brightness.dark
                        ? '切换浅色主题'
                        : '切换暗色主题',
                    onPressed: widget.onTheme,
                    icon: Icon(
                      Theme.of(context).brightness == Brightness.dark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                    ),
                  ),
                ],
              ),
        body: SafeArea(
          child: paired && !connection.busy
              ? Column(
                  children: [
                    if (!immersive && !compact)
                      Container(
                        padding: const EdgeInsets.only(left: 16),
                        decoration: BoxDecoration(
                          color: c.sidebar,
                          border: Border(bottom: BorderSide(color: c.line)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    connection.hostName!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    online
                                        ? '已连接'
                                        : connection.phase ==
                                              ConnectionPhase.connecting
                                        ? '正在连接…'
                                        : '暂时离线 · 显示上次数据',
                                    style: text.bodySmall?.copyWith(
                                      color: online ? c.success : c.warning,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!online)
                              IconButton(
                                tooltip: '重新连接',
                                onPressed: connection.reconnect,
                                icon: const Icon(Icons.refresh),
                              ),
                            TextButton(
                              onPressed: forget,
                              child: const Text('断开电脑'),
                            ),
                          ],
                        ),
                      ),
                    if (connection.error != null && !immersive)
                      Container(
                        width: double.infinity,
                        color: c.warningBg,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(
                          connection.error!,
                          style: TextStyle(color: c.warning, fontSize: 12),
                        ),
                      ),
                    Expanded(
                      child: WorkbenchCanvas(
                        connection: connection,
                        onImmersiveChanged: (value) =>
                            setState(() => immersive = value),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (connection.error != null)
                            Container(
                              margin: const EdgeInsets.only(bottom: 16),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: c.dangerBg,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                connection.error!,
                                style: TextStyle(color: c.danger),
                              ),
                            ),
                          if (connection.phase == ConnectionPhase.loading) ...[
                            const LinearProgressIndicator(),
                            const SizedBox(height: 24),
                            Text('正在读取连接', style: text.headlineSmall),
                          ] else if (connection.busy) ...[
                            const LinearProgressIndicator(),
                            const SizedBox(height: 24),
                            Text(
                              connection.phase == ConnectionPhase.approval
                                  ? '请在电脑上确认连接'
                                  : '正在连接电脑',
                              style: text.headlineSmall,
                            ),
                            const SizedBox(height: 16),
                            const Text('只在你正在操作的电脑上允许连接。'),
                            const SizedBox(height: 16),
                            OutlinedButton(
                              onPressed: connection.cancel,
                              child: const Text('取消连接'),
                            ),
                          ] else ...[
                            Text('电脑旁的另一块屏幕', style: text.headlineSmall),
                            const SizedBox(height: 16),
                            const Text('在电脑上打开 Desklet 连接助手，连接同一 Wi-Fi，即可开始。'),
                            const SizedBox(height: 24),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                FilledButton(
                                  onPressed: scan,
                                  child: const Text('扫码连接电脑'),
                                ),
                                OutlinedButton(
                                  onPressed: () => paste(),
                                  child: const Text('粘贴邀请'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 32),
                            const Divider(),
                            Row(
                              children: [
                                Expanded(
                                  child: Text('附近的电脑', style: text.titleLarge),
                                ),
                                TextButton(
                                  onPressed: connection.searching
                                      ? null
                                      : connection.discover,
                                  child: Text(
                                    connection.searching ? '正在搜索…' : '搜索',
                                  ),
                                ),
                              ],
                            ),
                            if (connection.nearby.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Text('可以直接扫码连接；自动搜索需要允许访问本地网络。'),
                              ),
                            for (final name in connection.nearby)
                              ListTile(
                                title: Text(name),
                                subtitle: const Text('在电脑上生成邀请后连接'),
                                onTap: () => paste(),
                              ),
                            if (connection.phase == ConnectionPhase.offline)
                              TextButton(
                                onPressed: connection.restore,
                                child: const Text('重试读取连接'),
                              ),
                            const SizedBox(height: 24),
                            Text(
                              '连接邀请仅在短时间内有效，且需要电脑确认。',
                              style: text.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      );
    },
  );
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final controller = MobileScannerController();
  bool captured = false;
  @override
  void dispose() {
    unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描电脑上的邀请')),
    body: MobileScanner(
      controller: controller,
      onDetect: (capture) {
        for (final barcode in capture.barcodes) {
          final value = barcode.rawValue;
          if (!captured &&
              value != null &&
              value.startsWith('desklet://pair?')) {
            captured = true;
            Navigator.pop(context, value);
            return;
          }
        }
      },
      errorBuilder: (context, error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('无法使用摄像头，可返回后粘贴完整邀请。', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
