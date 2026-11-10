import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models/catalog.dart';
import '../../core/models/guide.dart';
import '../../core/stores/guide_repository.dart';
import '../../theme.dart';
import '../live/live_controller.dart';

/// Where programmes sit on the grid's time axis.
class GuideLayout {
  GuideLayout({required DateTime now, this.hours = GuideRepository.hours})
      : start = _floorToHalfHour(now);

  static const pxPerMinute = 6.0;
  static const minBlockWidth = 6.0;

  /// The grid starts at the half hour before now, like the Android guide.
  final DateTime start;
  final int hours;

  DateTime get end => start.add(Duration(hours: hours));
  double get width => hours * 60 * pxPerMinute;

  double offsetOf(DateTime time) =>
      time.difference(start).inSeconds / 60 * pxPerMinute;

  /// Left edge and width of [programme], clipped to the window, or null when
  /// it lies wholly outside.
  ({double left, double width})? blockFor(Programme programme) {
    if (!programme.stop.isAfter(start) || !programme.start.isBefore(end)) return null;
    final left = offsetOf(programme.start).clamp(0.0, width);
    final right = offsetOf(programme.stop).clamp(0.0, width);
    if (right - left < minBlockWidth) return null;
    return (left: left, width: right - left);
  }

  static DateTime _floorToHalfHour(DateTime t) {
    final local = t.toLocal();
    return DateTime(local.year, local.month, local.day, local.hour, local.minute < 30 ? 0 : 30);
  }
}

String formatClock(DateTime time) {
  final t = time.toLocal();
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// The full TV guide: a 24-hour grid with category filters and search.
class GuideView extends StatefulWidget {
  const GuideView({
    super.key,
    required this.repository,
    required this.live,
    required this.onTune,
    required this.onBackToVideo,
  });

  final GuideRepository repository;
  final LiveController live;

  /// Tune a channel and go back to the video.
  final ValueChanged<Channel> onTune;
  final VoidCallback onBackToVideo;

  @override
  State<GuideView> createState() => _GuideViewState();
}

class _GuideViewState extends State<GuideView> {
  static const _labelWidth = 210.0;
  static const _rowHeight = 58.0;
  static const _headerHeight = 34.0;

  final _vertical = ScrollController();
  final _labels = ScrollController();
  final _horizontal = ScrollController();
  final _search = TextEditingController();

  late GuideLayout _layout = GuideLayout(now: DateTime.now());
  Guide? _guide;
  String? _error;
  bool _loading = false;
  String? _categoryId;
  String _query = '';
  Timer? _debounce;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _guide = widget.repository.guide;
    _vertical.addListener(_syncLabels);
    // Keeps the "now" line and on-now highlights current.
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _clock?.cancel();
    _vertical.dispose();
    _labels.dispose();
    _horizontal.dispose();
    _search.dispose();
    super.dispose();
  }

  void _syncLabels() {
    if (_labels.hasClients && _labels.offset != _vertical.offset) {
      _labels.jumpTo(_vertical.offset);
    }
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final guide = await widget.repository.load(force: force);
      if (!mounted) return;
      setState(() {
        _guide = guide;
        _layout = GuideLayout(now: DateTime.now());
      });
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't load the guide. $e");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = value.trim().toLowerCase());
    });
  }

  List<GuideChannel> _visibleChannels(Guide guide) {
    Iterable<GuideChannel> channels = guide.channels;
    final categoryId = _categoryId;
    if (categoryId != null) {
      GuideCategory? category;
      for (final c in guide.categories) {
        if (c.id == categoryId) category = c;
      }
      if (category != null) {
        final byId = {for (final c in guide.channels) c.id: c};
        channels = [
          for (final id in category.streamIds)
            if (byId[id] != null) byId[id]!,
        ];
      }
    }
    if (_query.isNotEmpty) {
      channels = channels.where(
        (c) =>
            c.name.toLowerCase().contains(_query) ||
            c.programmes.any((p) => p.title.toLowerCase().contains(_query)),
      );
    }
    return channels.toList(growable: false);
  }

  Channel _toChannel(GuideChannel channel) =>
      widget.live.catalog.channelsById[channel.id] ??
      Channel(
        id: channel.id,
        number: channel.number,
        name: channel.name,
        type: channel.type,
        categoryId: channel.categoryId,
      );

  void _onProgramme(GuideChannel channel, Programme programme, bool onNow) {
    if (onNow) {
      widget.onTune(_toChannel(channel));
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(programme.title.isEmpty ? channel.name : programme.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${channel.name}  ·  ${formatClock(programme.start)} – '
                '${formatClock(programme.stop)}',
                style: const TextStyle(color: ZipColors.textSecondary),
              ),
              if (programme.description != null && programme.description!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(programme.description!),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onTune(_toChannel(channel));
            },
            child: const Text('Watch channel now'),
          ),
        ],
      ),
    );
  }

  void _jumpToNow() {
    if (!_horizontal.hasClients) return;
    _horizontal.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final guide = _guide;
    return ColoredBox(
      color: ZipColors.background,
      child: Column(
        children: [
          _header(guide),
          const Divider(height: 1),
          Expanded(child: _body(guide)),
        ],
      ),
    );
  }

  Widget _header(Guide? guide) {
    final live = widget.live;
    final current = live.current;
    final categories = [
      for (final c in guide?.categories ?? const <GuideCategory>[])
        if (!c.hidden) c,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('TV Guide', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 300,
                      child: TextField(
                        controller: _search,
                        onChanged: _onSearch,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search channels and programmes',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          filled: true,
                          fillColor: ZipColors.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _jumpToNow,
                      icon: const Icon(Icons.schedule, size: 18),
                      label: const Text('Now'),
                    ),
                    IconButton(
                      tooltip: 'Refresh guide',
                      onPressed: _loading ? null : () => _load(force: true),
                      icon: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      _chip('All', null),
                      for (final c in categories)
                        _chip(
                          c.icon == null || c.icon!.isEmpty ? c.name : '${c.icon} ${c.name}',
                          c.id,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // What is playing keeps going while browsing; click to go back to it.
          Tooltip(
            message: 'Back to video',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: widget.onBackToVideo,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 160,
                        height: 90,
                        child: Video(
                          controller: live.player.controller,
                          controls: NoVideoControls,
                          fill: Colors.black,
                        ),
                      ),
                    ),
                    if (current != null)
                      SizedBox(
                        width: 160,
                        child: Text(
                          current.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12, color: ZipColors.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String? id) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: _categoryId == id,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        onSelected: (_) {
          setState(() => _categoryId = id);
          if (_vertical.hasClients) _vertical.jumpTo(0);
        },
      ),
    );
  }

  Widget _body(Guide? guide) {
    if (guide == null) {
      if (_error != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final channels = _visibleChannels(guide);
    if (channels.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty ? 'No channels in this category.' : 'Nothing matches "$_query".',
          style: const TextStyle(color: ZipColors.textMuted),
        ),
      );
    }

    final now = DateTime.now();
    final layout = _layout;
    final nowX = layout.offsetOf(now);
    final currentId = widget.live.current?.id;

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        return Row(
          children: [
            // Channel names stay put while the grid scrolls sideways.
            SizedBox(
              width: _labelWidth,
              child: Column(
                children: [
                  const SizedBox(height: _headerHeight),
                  Expanded(
                    child: Listener(
                      onPointerSignal: (signal) {
                        if (signal is PointerScrollEvent && _vertical.hasClients) {
                          final position = _vertical.position;
                          _vertical.jumpTo(
                            (_vertical.offset + signal.scrollDelta.dy)
                                .clamp(position.minScrollExtent, position.maxScrollExtent),
                          );
                        }
                      },
                      child: ListView.builder(
                        controller: _labels,
                        physics: const NeverScrollableScrollPhysics(),
                        itemExtent: _rowHeight,
                        itemCount: channels.length,
                        itemBuilder: (context, index) {
                          final channel = channels[index];
                          return _ChannelLabel(
                            channel: channel,
                            playing: channel.id == currentId,
                            onTap: () => widget.onTune(_toChannel(channel)),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Scrollbar(
                controller: _horizontal,
                child: SingleChildScrollView(
                  controller: _horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: layout.width,
                    height: height,
                    child: Stack(
                      children: [
                        Column(
                          children: [
                            _TimeHeader(layout: layout, height: _headerHeight),
                            Expanded(
                              child: ListView.builder(
                                controller: _vertical,
                                itemExtent: _rowHeight,
                                itemCount: channels.length,
                                itemBuilder: (context, index) => _ProgrammeRow(
                                  channel: channels[index],
                                  layout: layout,
                                  now: now,
                                  onProgramme: _onProgramme,
                                  onEmpty: (c) => widget.onTune(_toChannel(c)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (nowX >= 0 && nowX <= layout.width)
                          Positioned(
                            left: nowX,
                            top: 0,
                            bottom: 0,
                            child: const IgnorePointer(
                              child: VerticalDivider(
                                width: 2,
                                thickness: 2,
                                color: ZipColors.offline,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ChannelLabel extends StatelessWidget {
  const _ChannelLabel({required this.channel, required this.playing, required this.onTap});

  final GuideChannel channel;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: playing ? ZipColors.surfaceHigh : ZipColors.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: ZipColors.background)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: Text(
                  channel.number?.toString() ?? '',
                  style: const TextStyle(color: ZipColors.textMuted, fontSize: 13),
                ),
              ),
              Expanded(
                child: Text(
                  channel.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: playing ? FontWeight.w600 : FontWeight.w400,
                    color: playing ? ZipColors.accent : ZipColors.text,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeHeader extends StatelessWidget {
  const _TimeHeader({required this.layout, required this.height});

  final GuideLayout layout;
  final double height;

  @override
  Widget build(BuildContext context) {
    const slot = 30 * GuideLayout.pxPerMinute;
    final slots = layout.hours * 2;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          for (var i = 0; i < slots; i++)
            Container(
              width: slot,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 8),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: ZipColors.surfaceHigh)),
              ),
              child: Text(
                formatClock(layout.start.add(Duration(minutes: 30 * i))),
                style: const TextStyle(fontSize: 12, color: Color(0xFFA0AEC0)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ProgrammeRow extends StatelessWidget {
  const _ProgrammeRow({
    required this.channel,
    required this.layout,
    required this.now,
    required this.onProgramme,
    required this.onEmpty,
  });

  final GuideChannel channel;
  final GuideLayout layout;
  final DateTime now;
  final void Function(GuideChannel channel, Programme programme, bool onNow) onProgramme;
  final ValueChanged<GuideChannel> onEmpty;

  @override
  Widget build(BuildContext context) {
    final onNow = programmeOnNow(channel.programmes, now);
    final blocks = <Widget>[];
    for (final programme in channel.programmes) {
      final box = layout.blockFor(programme);
      if (box == null) continue;
      final isNow = identical(programme, onNow);
      blocks.add(
        Positioned(
          left: box.left,
          width: box.width,
          top: 0,
          bottom: 0,
          child: _ProgrammeBlock(
            programme: programme,
            onNow: isNow,
            onTap: () => onProgramme(channel, programme, isNow),
          ),
        ),
      );
    }
    if (blocks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(2),
        child: Material(
          color: ZipColors.surface,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => onEmpty(channel),
            child: const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 12),
                child: Text(
                  'No guide information',
                  style: TextStyle(color: ZipColors.textMuted, fontSize: 13),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Stack(children: blocks);
  }
}

class _ProgrammeBlock extends StatelessWidget {
  const _ProgrammeBlock({required this.programme, required this.onNow, required this.onTap});

  final Programme programme;
  final bool onNow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Tooltip(
        waitDuration: const Duration(milliseconds: 600),
        message: '${programme.title}\n'
            '${formatClock(programme.start)} – ${formatClock(programme.stop)}',
        child: Material(
          color: onNow ? const Color(0xFF1A4A6E) : ZipColors.surface,
          borderRadius: BorderRadius.circular(4),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    programme.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: onNow ? ZipColors.accent : ZipColors.text,
                    ),
                  ),
                  Text(
                    '${formatClock(programme.start)} – ${formatClock(programme.stop)}',
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: const TextStyle(fontSize: 11, color: ZipColors.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
