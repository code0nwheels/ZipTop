import 'package:flutter/material.dart';

import '../theme.dart';

/// A flat tappable surface in the web viewer's style: the fill fades to
/// [hoverColor] over 150 ms on hover, there is no ripple or scale, and
/// keyboard focus draws a 3px pale-blue ring outside the shape (like a TV
/// remote's focus).
class ZipTappable extends StatefulWidget {
  const ZipTappable({
    super.key,
    required this.child,
    this.onTap,
    this.onDoubleTap,
    this.onSecondaryTapUp,
    this.onHover,
    this.color = Colors.transparent,
    this.hoverColor = ZipColors.hover,
    this.borderRadius = ZipRadius.smAll,
    this.border,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = true,
    this.mouseCursor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final GestureTapUpCallback? onSecondaryTapUp;
  final ValueChanged<bool>? onHover;
  final Color color;
  final Color? hoverColor;
  final BorderRadius borderRadius;
  final BoxBorder? border;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool canRequestFocus;
  final MouseCursor? mouseCursor;

  @override
  State<ZipTappable> createState() => _ZipTappableState();
}

class _ZipTappableState extends State<ZipTappable> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final fill = _hover && widget.hoverColor != null
        ? widget.hoverColor!
        : widget.color;
    final enabled = widget.onTap != null || widget.onDoubleTap != null;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: enabled && widget.canRequestFocus,
      mouseCursor: widget.mouseCursor ??
          (enabled ? SystemMouseCursors.click : MouseCursor.defer),
      onShowHoverHighlight: (v) {
        setState(() => _hover = v);
        widget.onHover?.call(v);
      },
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTapUp: widget.onSecondaryTapUp,
        child: AnimatedContainer(
          duration: ZipMotion.fast,
          curve: ZipMotion.curve,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: widget.borderRadius,
            border: widget.border,
          ),
          foregroundDecoration: _focus
              ? BoxDecoration(
                  borderRadius: widget.borderRadius,
                  border: Border.all(
                    color: ZipColors.focus,
                    width: 3,
                    strokeAlign: BorderSide.strokeAlignOutside,
                  ),
                )
              : null,
          child: widget.child,
        ),
      ),
    );
  }
}
