import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class UpdateSettings extends StatefulWidget {
  const UpdateSettings({super.key});

  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings> {
  static const channel = MethodChannel('app.deskbar/update');
  String? current;
  String? version;
  String? message;
  bool busy = false;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    channel
        .invokeMethod<String>('version')
        .then((value) {
          if (mounted) setState(() => current = value);
        })
        .catchError((Object _) {});
  }

  Future<void> run() async {
    if (busy) return;
    final installing = version != null;
    setState(() {
      busy = true;
      failed = false;
      message = installing ? '正在下载并验证…' : '正在检查…';
    });
    try {
      if (installing) {
        final result = await channel.invokeMethod<String>('install');
        if (!mounted) return;
        setState(() {
          message = result == 'permission_required'
              ? '允许安装后，返回这里再次点击安装更新。'
              : '已打开安装程序，请按系统提示完成安装。';
        });
      } else {
        final result = await channel.invokeMapMethod<String, dynamic>('check');
        if (!mounted) return;
        setState(() {
          current = result?['currentVersion'] as String?;
          version = result?['version'] as String?;
          message = version == null ? '已是最新版本' : '发现新版本 $version';
        });
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        version = null;
        failed = true;
        message = error.message ?? '更新未完成，请重试';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        version = null;
        failed = true;
        message = '无法检查更新，请在 Android 应用中重试';
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          current == null ? '软件更新' : '软件更新 · $current',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (message != null)
          Text(
            message!,
            style: failed
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null,
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: busy ? null : run,
          child: Text(busy ? '请稍候…' : (version == null ? '检查更新' : '安装更新')),
        ),
      ],
    ),
  );
}
