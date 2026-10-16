import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'connection.dart';

void main() => runApp(const DeskletApp());

class DeskletApp extends StatelessWidget {
  const DeskletApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Desklet',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffbfd3b0),
        brightness: Brightness.dark,
        surface: const Color(0xff171919),
      ),
      scaffoldBackgroundColor: const Color(0xff171919),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xff171919),
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xff232923),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
      ),
    ),
    home: const Workbench(),
  );
}

class Workbench extends StatefulWidget {
  const Workbench({super.key});
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> with WidgetsBindingObserver {
  final connection = Connection();
  bool pasteOpen = false;
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
        title: const Text('粘贴连接邀请'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('在电脑上的 Desklet 点击「连接设备」，复制完整邀请。'),
                const SizedBox(height: 20),
                TextField(
                  controller: invitation,
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
        title: const Text('断开这台电脑？'),
        content: const Text('此设备会清除连接信息。再次使用需要重新配对。你也可以在电脑上移除这台设备。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
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
      return Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              Icon(Icons.desktop_windows_outlined, size: 22),
              SizedBox(width: 10),
              Text('Desklet', style: TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          actions: [
            if (paired)
              IconButton(
                onPressed: forget,
                tooltip: '断开电脑',
                icon: const Icon(Icons.link_off),
              ),
            const SizedBox(width: 10),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (connection.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Material(
                          color: const Color(0xff3a2b25),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(connection.error!),
                          ),
                        ),
                      ),
                    if (connection.phase == ConnectionPhase.loading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(40),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (connection.busy) ...[
                      const SizedBox(height: 32),
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: 28),
                      Text(
                        connection.phase == ConnectionPhase.approval
                            ? '请在电脑上确认连接'
                            : '正在连接电脑',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '只在你正在操作的电脑上允许连接。',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      Center(
                        child: OutlinedButton(
                          onPressed: connection.cancel,
                          child: const Text('取消连接'),
                        ),
                      ),
                    ] else if (paired) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: Row(
                            children: [
                              const Icon(Icons.computer, size: 34),
                              const SizedBox(width: 18),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      connection.hostName!,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      online
                                          ? '已连接'
                                          : connection.phase ==
                                                ConnectionPhase.connecting
                                          ? '正在连接…'
                                          : '暂时离线',
                                      style: TextStyle(
                                        color: online
                                            ? const Color(0xffbfd3b0)
                                            : Colors.white54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (!online)
                                IconButton(
                                  onPressed: connection.reconnect,
                                  tooltip: '重新连接',
                                  icon: const Icon(Icons.refresh),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 36),
                      const Icon(
                        Icons.dashboard_outlined,
                        size: 48,
                        color: Color(0xff899980),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        online ? '电脑已连接' : '等待电脑恢复连接',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        online
                            ? '工作台还没有内容。会话、额度和快捷入口将在后续版本中加入。'
                            : '请保持电脑上的 Desklet 运行，并连接同一局域网。恢复后会自动重连。',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white60,
                          height: 1.7,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 30),
                      const Icon(
                        Icons.devices_outlined,
                        size: 76,
                        color: Color(0xffbfd3b0),
                      ),
                      const SizedBox(height: 28),
                      Text(
                        '电脑旁的另一块屏幕',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '在电脑和这里打开 Desklet，\n连接同一 Wi-Fi，即可开始。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white60, height: 1.8),
                      ),
                      const SizedBox(height: 32),
                      Center(
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          alignment: WrapAlignment.center,
                          children: [
                            FilledButton.icon(
                              onPressed: scan,
                              icon: const Icon(Icons.qr_code_scanner),
                              label: const Text('扫码连接电脑'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => paste(),
                              icon: const Icon(Icons.content_paste),
                              label: const Text('粘贴邀请'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 36),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '附近的电脑',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: connection.searching
                                ? null
                                : connection.discover,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: Text(connection.searching ? '正在搜索…' : '搜索'),
                          ),
                        ],
                      ),
                      if (connection.nearby.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: Text(
                            '可以直接扫码连接；自动搜索需要允许访问本地网络。',
                            style: TextStyle(color: Colors.white54),
                          ),
                        ),
                      for (final name in connection.nearby)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.computer),
                            title: Text(name),
                            subtitle: const Text('在电脑上生成邀请后连接'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => paste(),
                          ),
                        ),
                    ],
                    if (!connection.busy &&
                        !paired &&
                        connection.phase == ConnectionPhase.offline)
                      TextButton(
                        onPressed: connection.restore,
                        child: const Text('重试读取连接'),
                      ),
                    const SizedBox(height: 32),
                    const Text(
                      '连接邀请仅在短时间内有效，且需要电脑确认。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    ),
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
              const Icon(Icons.no_photography_outlined, size: 48),
              const SizedBox(height: 20),
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
