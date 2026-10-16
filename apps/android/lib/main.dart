import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'connection.dart';
import 'workbench_content.dart';
import 'rawblock.dart';

void main() => runApp(const DeskletApp());

class DeskletApp extends StatelessWidget {
  const DeskletApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Desklet 工作台',
    debugShowCheckedModeBanner: false,
    theme: rawBlockTheme(),
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
      return Scaffold(
        appBar: AppBar(
          title: const Text('Desklet 工作台', style: TextStyle(fontSize: 22)),
          shape: const Border(bottom: BorderSide(width: 3)),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (connection.error != null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 24),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          border: Border.all(color: rawError, width: 3),
                        ),
                        child: Text(connection.error!),
                      ),
                    if (connection.phase == ConnectionPhase.loading) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 24),
                      Text('正在读取连接', style: text.headlineSmall),
                    ] else if (connection.busy) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 32),
                      Text(
                        connection.phase == ConnectionPhase.approval
                            ? '请在电脑上\n确认连接'
                            : '正在连接电脑',
                        style: text.headlineMedium,
                      ),
                      const SizedBox(height: 24),
                      const Text('只在你正在操作的电脑上允许连接。'),
                      const SizedBox(height: 24),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton(
                          onPressed: connection.cancel,
                          child: const Text('取消连接'),
                        ),
                      ),
                    ] else if (paired) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('连接的电脑', style: text.bodySmall),
                              const SizedBox(height: 12),
                              Text(
                                connection.hostName!,
                                style: text.titleLarge,
                              ),
                              const SizedBox(height: 16),
                              StatusTag(
                                online
                                    ? '已连接'
                                    : connection.phase ==
                                          ConnectionPhase.connecting
                                    ? '正在连接…'
                                    : '暂时离线',
                                color: online ? rawSuccess : Colors.black,
                              ),
                              const SizedBox(height: 16),
                              Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                children: [
                                  if (!online)
                                    TextButton(
                                      onPressed: connection.reconnect,
                                      child: const Text('重新连接'),
                                    ),
                                  TextButton(
                                    onPressed: forget,
                                    child: const Text('断开电脑'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      WorkbenchContent(connection: connection),
                    ] else ...[
                      const SizedBox(height: 16),
                      Text('电脑旁的\n另一块屏幕', style: text.headlineMedium),
                      const SizedBox(height: 24),
                      const Text('在电脑上打开 Desklet 连接助手，连接同一 Wi-Fi，即可开始。'),
                      const SizedBox(height: 32),
                      Wrap(
                        spacing: 12,
                        runSpacing: 16,
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
                      const SizedBox(height: 40),
                      const Divider(height: 3, thickness: 3),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Text('附近的电脑', style: text.titleLarge),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: connection.searching
                                ? null
                                : connection.discover,
                            child: Text(connection.searching ? '正在搜索…' : '搜索'),
                          ),
                        ],
                      ),
                      if (connection.nearby.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text('可以直接扫码连接；自动搜索需要允许访问本地网络。'),
                        ),
                      for (final name in connection.nearby)
                        ListTile(
                          title: Text(name),
                          subtitle: const Text('在电脑上生成邀请后连接'),
                          onTap: () => paste(),
                        ),
                    ],
                    if (!connection.busy &&
                        !paired &&
                        connection.phase == ConnectionPhase.offline)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: connection.restore,
                          child: const Text('重试读取连接'),
                        ),
                      ),
                    const SizedBox(height: 32),
                    Text('连接邀请仅在短时间内有效，且需要电脑确认。', style: text.bodySmall),
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
