import 'dart:async';
import 'package:flutter/material.dart';
import 'rawblock.dart';

final _notices = Expando<OverlayEntry>();

void showTopNotice(BuildContext context, String message) {
  final overlay = Navigator.of(context, rootNavigator: true).overlay!;
  final previous = _notices[overlay];
  previous?.remove();
  previous?.dispose();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _TopNotice(
      message: message,
      onDismiss: () {
        if (_notices[overlay] != entry) return;
        _notices[overlay] = null;
        entry.remove();
        entry.dispose();
      },
    ),
  );
  _notices[overlay] = entry;
  overlay.insert(entry);
}

class _TopNotice extends StatefulWidget {
  const _TopNotice({required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  State<_TopNotice> createState() => _TopNoticeState();
}

class _TopNoticeState extends State<_TopNotice> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 5), widget.onDismiss);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = deskletColors(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: SafeArea(
          bottom: false,
          minimum: const EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Semantics(
                liveRegion: true,
                child: Material(
                  color: c.accent,
                  elevation: 2,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Text(
                      widget.message,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: c.onAccent),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
