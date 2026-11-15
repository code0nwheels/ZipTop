import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Turns the mouse wheel over [child] into volume: up is louder, down is
/// quieter, and a pill at the top shows the new level for a moment.
class WheelVolume extends StatefulWidget {
  const WheelVolume({
    super.key,
    required this.volume,
    required this.onChanged,
    this.onActivity,
    this.compact = false,
    required this.child,
  });

  /// The current volume, 0 to 100.
  final double Function() volume;
  final ValueChanged<double> onChanged;

  /// Called on every wheel turn, so the controls can come up.
  final VoidCallback? onActivity;

  /// A smaller pill, for the mini player and multiview tiles.
  final bool compact;
  final Widget child;

  /// Volume points per wheel notch.
  static const step = 5.0;

  @override
  State<WheelVolume> createState() => _WheelVolumeState();
}

class _WheelVolumeState extends State<WheelVolume> {
  /// A mouse notch scrolls tens of pixels in one event; a smooth-scrolling
  /// mouse sends many small ones, which add up to a notch here.
  static const _pixelsPerNotch = 40.0;

  double _pending = 0;
  double? _shown;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    // Let a scrollable underneath the pointer (a menu, a list) win.
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final dy = (event as PointerScrollEvent).scrollDelta.dy;
      int notches;
      if (dy.abs() >= _pixelsPerNotch / 2) {
        _pending = 0;
        notches = dy < 0 ? 1 : -1;
      } else {
        _pending -= dy;
        notches = (_pending / _pixelsPerNotch).truncate();
        _pending -= notches * _pixelsPerNotch;
      }
      if (notches == 0) return;
      final next = (widget.volume() + notches * WheelVolume.step).clamp(
        0.0,
        100.0,
      );
      widget.onActivity?.call();
      widget.onChanged(next);
      _hide?.cancel();
      _hide = Timer(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _shown = null);
      });
      setState(() => _shown = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return Listener(
      onPointerSignal: _onSignal,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          Positioned(
            top: widget.compact ? 10 : 20,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: shown == null ? 0 : 1,
                duration: ZipMotion.fast,
                child: Center(
                  child: _VolumePill(
                    volume: shown ?? widget.volume(),
                    compact: widget.compact,
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

class _VolumePill extends StatelessWidget {
  const _VolumePill({required this.volume, required this.compact});

  final double volume;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final icon = volume == 0
        ? Icons.volume_off
        : volume < 50
        ? Icons.volume_down
        : Icons.volume_up;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: ZipColors.overlayPill,
        borderRadius: ZipRadius.pillAll,
        border: Border.all(color: ZipColors.lineHi),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 16 : 20, color: ZipColors.text),
          SizedBox(width: compact ? 6 : 8),
          Text(
            '${volume.round()}%',
            style: ZipText.mono(
              fontSize: compact ? 13 : 16,
              fontWeight: FontWeight.w600,
              color: ZipColors.text,
            ),
          ),
        ],
      ),
    );
  }
}
