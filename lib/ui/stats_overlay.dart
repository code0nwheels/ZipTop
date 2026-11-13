import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/mpv_player.dart' show formatBitrate;
import '../player/playback_stats.dart';
import '../theme.dart';

/// The "Stats for nerds" panel, drawn over the top-left of a video. Reads
/// the player once a second while it is up.
class StatsOverlay extends StatefulWidget {
  const StatsOverlay({
    super.key,
    required this.read,
    required this.onClose,
    this.compact = false,
    this.top = 0,
  });

  /// Asked anew each poll, so a player that is swapped out (a rebuilt
  /// multiview tile) is followed.
  final Future<PlaybackStats> Function() read;
  final VoidCallback onClose;

  /// Small type and no graphs, for multiview tiles and the mini player.
  final bool compact;

  /// Extra space above the panel, to clear a top bar.
  final double top;

  static const pollEvery = Duration(seconds: 1);

  /// Samples kept for the graphs: a minute at [pollEvery].
  static const history = 60;

  @override
  State<StatsOverlay> createState() => _StatsOverlayState();
}

class _StatsOverlayState extends State<StatsOverlay> {
  Timer? _timer;
  bool _reading = false;
  PlaybackStats _stats = PlaybackStats.empty;
  final _connection = <double>[];
  final _buffer = <double>[];

  @override
  void initState() {
    super.initState();
    unawaited(_poll());
    _timer = Timer.periodic(StatsOverlay.pollEvery, (_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_reading) return;
    _reading = true;
    PlaybackStats stats;
    try {
      stats = await widget.read();
    } catch (_) {
      stats = PlaybackStats.empty;
    } finally {
      _reading = false;
    }
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _push(_connection, stats.downloadRate?.toDouble());
      _push(_buffer, stats.bufferSeconds);
    });
  }

  static void _push(List<double> samples, double? value) {
    samples.add(value ?? 0);
    if (samples.length > StatsOverlay.history) samples.removeAt(0);
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    final inset = compact ? 8.0 : 12.0;
    final fontSize = compact ? 10.0 : 12.0;
    return LayoutBuilder(
      builder: (context, box) {
        final rows = statsRows(_stats, viewport: box.biggest);
        // Compact, it shares a small picture with a tile's options button
        // (top right) and channel label (bottom): leave them room.
        final right = compact ? inset + 36 : inset;
        final bottom = compact ? inset + 32 : inset;
        final room = math.max(0.0, box.maxWidth - inset - right);
        final maxWidth = compact ? room : math.min(360.0, room);
        final maxHeight = math.max(0.0, box.maxHeight - inset - bottom - widget.top);
        return Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.fromLTRB(inset, inset + widget.top, right, bottom),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: ZipColors.overlayPill,
                  borderRadius: ZipRadius.mdAll,
                  border: Border.all(color: ZipColors.lineHi),
                ),
                child: ClipRRect(
                  borderRadius: ZipRadius.mdAll,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(compact ? 8 : 12, 4, 4, compact ? 6 : 10),
                    child: IntrinsicWidth(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _Header(
                            compact: compact,
                            onCopy: () => _copy(context, rows),
                            onClose: widget.onClose,
                          ),
                          if (rows.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Text(
                                'Waiting for the player…',
                                style: ZipText.mono(fontSize: fontSize),
                              ),
                            ),
                          for (final (label, value) in rows)
                            Padding(
                              padding: const EdgeInsets.only(right: 8, bottom: 1),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: fontSize * 8.5,
                                    child: Text(label, style: ZipText.mono(fontSize: fontSize)),
                                  ),
                                  Flexible(
                                    child: Text(
                                      value,
                                      style: ZipText.mono(fontSize: fontSize, color: ZipColors.text),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (!compact) ...[
                            const SizedBox(height: 8),
                            _Graph(
                              label: 'Connection',
                              value: _stats.downloadRate == null
                                  ? '–'
                                  : formatBitrate(_stats.downloadRate!),
                              samples: _connection,
                              color: ZipColors.info,
                            ),
                            const SizedBox(height: 6),
                            _Graph(
                              label: 'Buffer health',
                              value: _stats.bufferSeconds == null
                                  ? '–'
                                  : '${_stats.bufferSeconds!.toStringAsFixed(1)} s',
                              samples: _buffer,
                              color: ZipColors.success,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _copy(BuildContext context, List<(String, String)> rows) {
    final text = [for (final (label, value) in rows) '$label: $value'].join('\n');
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('Stats copied')));
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.compact, required this.onCopy, required this.onClose});

  final bool compact;
  final VoidCallback onCopy;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final iconSize = compact ? 14.0 : 16.0;
    final button = BoxConstraints.tightFor(width: iconSize + 12, height: iconSize + 12);
    return Row(
      children: [
        Expanded(
          child: Text(
            'Stats for nerds',
            style: TextStyle(
              fontSize: compact ? 11 : 13,
              fontWeight: FontWeight.w700,
              color: ZipColors.text,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy stats',
          onPressed: onCopy,
          iconSize: iconSize,
          padding: EdgeInsets.zero,
          constraints: button,
          icon: const Icon(Icons.copy_rounded),
        ),
        IconButton(
          tooltip: 'Close stats (S)',
          onPressed: onClose,
          iconSize: iconSize,
          padding: EdgeInsets.zero,
          constraints: button,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }
}

/// A label, the latest value and a line of the last minute.
class _Graph extends StatelessWidget {
  const _Graph({
    required this.label,
    required this.value,
    required this.samples,
    required this.color,
  });

  final String label;
  final String value;
  final List<double> samples;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        children: [
          SizedBox(width: 102, child: Text(label, style: ZipText.mono(fontSize: 12))),
          SizedBox(
            width: 120,
            height: 18,
            child: CustomPaint(painter: _SparklinePainter(List.of(samples), color)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: ZipText.mono(fontSize: 12, color: ZipColors.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.samples, this.color);

  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..color = ZipColors.lineHi
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), baseline);
    if (samples.length < 2) return;
    final top = samples.reduce(math.max);
    if (top <= 0) return;
    final step = size.width / (StatsOverlay.history - 1);
    // Newest at the right edge.
    final start = size.width - step * (samples.length - 1);
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = start + step * i;
      final y = size.height - 1 - (samples[i] / top) * (size.height - 2);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => true;
}

/// A right-click menu over a video with the one item that turns the stats
/// panel on or off.
Future<void> showStatsMenu(
  BuildContext context,
  Offset globalPosition, {
  required bool on,
  required VoidCallback onToggle,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final picked = await showMenu<bool>(
    context: context,
    position: RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlay.size),
    items: [
      CheckedPopupMenuItem<bool>(
        value: true,
        checked: on,
        child: const Text('Stats for nerds (S)'),
      ),
    ],
  );
  if (picked == true) onToggle();
}
