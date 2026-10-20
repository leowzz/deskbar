import 'package:flutter/material.dart';

/// Labels are painted over measured content; toggling does not change layout.
class LayoutDebugOverlay extends StatelessWidget {
  const LayoutDebugOverlay({
    super.key,
    required this.enabled,
    required this.label,
    required this.child,
    this.top = false,
    this.forceBorder = false,
    this.forceLabel = false,
  });
  final bool enabled, top, forceBorder, forceLabel;
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => _LayoutDebugOverlayStateful(
    enabled: enabled,
    top: top,
    label: label,
    forceBorder: forceBorder,
    forceLabel: forceLabel,
    child: child,
  );
}

class _LayoutDebugOverlayStateful extends StatefulWidget {
  const _LayoutDebugOverlayStateful({
    required this.enabled,
    required this.top,
    required this.label,
    required this.child,
    required this.forceBorder,
    required this.forceLabel,
  });

  final bool enabled, top, forceBorder, forceLabel;
  final String label;
  final Widget child;

  @override
  State<_LayoutDebugOverlayStateful> createState() =>
      _LayoutDebugOverlayStatefulState();
}

class _LayoutDebugOverlayStatefulState
    extends State<_LayoutDebugOverlayStateful> {
  bool hovered = false;

  void _setHovered(bool value) {
    if (hovered == value || !widget.enabled) return;
    setState(() => hovered = value);
  }

  @override
  void didUpdateWidget(covariant _LayoutDebugOverlayStateful oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && hovered) hovered = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final showBorder = hovered || widget.forceBorder;
    final showLabel = hovered || widget.forceLabel;
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Stack(
        // Keep the child's intrinsic height when an item sits in a
        // scrolling column; StackFit.expand would pass an infinite height
        // constraint through to Text during layout.
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (showBorder)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: hovered ? const Color(0x14527bc2) : null,
                    border: Border.all(
                      color: const Color(0xaa527bc2),
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),
          if (showLabel)
            Positioned(
              left: 0,
              right: 0,
              top: widget.top ? 0 : null,
              bottom: widget.top ? null : 0,
              child: IgnorePointer(
                child: ColoredBox(
                  color: const Color(0xb8303e52),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: ExcludeSemantics(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
