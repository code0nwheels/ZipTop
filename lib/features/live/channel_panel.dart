import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/catalog.dart';
import '../../core/stores/catalog_store.dart';
import '../../theme.dart';
import '../../ui/ch_num_chip.dart';
import '../../ui/channel_hue.dart';
import '../../ui/focus_ring.dart';
import 'live_controller.dart';

/// Id of the local "Recent" row, which the server knows nothing about.
const recentCategoryId = 'local:recent';

typedef TuneCallback = void Function(Channel channel, List<Channel> scope, String scopeName);

/// Categories on the left, the selected row's channels on the right, and a
/// search box over both.
class ChannelPanel extends StatefulWidget {
  const ChannelPanel({
    super.key,
    required this.live,
    required this.selectedCategoryId,
    required this.onSelectCategory,
    required this.searchController,
    required this.searchFocus,
    required this.onTune,
    required this.showCategories,
    required this.categoriesWidth,
    required this.onToggleCategories,
    required this.onHide,
  });

  final LiveController live;
  final String? selectedCategoryId;
  final ValueChanged<String> onSelectCategory;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final TuneCallback onTune;

  /// Whether the category column is shown. Without it, the row is picked
  /// from a menu above the channel list.
  final bool showCategories;
  final double categoriesWidth;
  final VoidCallback onToggleCategories;

  /// Hide the whole panel.
  final VoidCallback onHide;

  @override
  State<ChannelPanel> createState() => _ChannelPanelState();
}

class _ChannelPanelState extends State<ChannelPanel> {
  String? _feedId;
  Timer? _clock;

  CatalogStore get _catalog => widget.live.catalog;

  @override
  void initState() {
    super.initState();
    widget.searchController.addListener(_changed);
    // Keeps the now-playing progress bars moving.
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => _changed());
  }

  @override
  void didUpdateWidget(ChannelPanel old) {
    super.didUpdateWidget(old);
    if (old.selectedCategoryId != widget.selectedCategoryId) _feedId = null;
    if (old.searchController != widget.searchController) {
      old.searchController.removeListener(_changed);
      widget.searchController.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.searchController.removeListener(_changed);
    _clock?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Matches the Android app's search: channel name or what is on now.
  List<Channel> _search(String query) {
    final q = query.toLowerCase();
    return [
      for (final c in _catalog.allChannels)
        if (c.name.toLowerCase().contains(q) ||
            (c.nowPlaying?.title?.toLowerCase().contains(q) ?? false))
          c,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.live;
    final query = widget.searchController.text.trim();
    final searching = query.isNotEmpty;
    final showRecents = live.settings.recentsEnabled && live.recents.isNotEmpty;
    final categories = _catalog.visibleCategories;

    var selectedId = widget.selectedCategoryId;
    final known = selectedId == recentCategoryId
        ? showRecents
        : categories.any((c) => c.id == selectedId);
    if (!known) {
      selectedId = categories.any((c) => c.id == CategoryIds.all)
          ? CategoryIds.all
          : (categories.isEmpty ? null : categories.first.id);
    }
    final selected = _catalog.category(selectedId);

    List<Channel> channels;
    String title;
    var feeds = const <Feed>[];
    if (searching) {
      channels = _search(query);
      title = 'Search';
    } else if (selectedId == recentCategoryId) {
      channels = live.recents;
      title = 'Recent';
    } else if (selected != null) {
      channels = _catalog.channelsIn(selected);
      title = selected.name;
      if (selected.feeds.length > 1) {
        feeds = selected.feeds;
        Feed? feed;
        for (final f in feeds) {
          if (f.id == _feedId) feed = f;
        }
        if (feed != null) {
          final ids = feed.streamIds.toSet();
          channels = [
            for (final c in channels)
              if (ids.contains(c.id)) c,
          ];
        }
      }
    } else {
      channels = const [];
      title = '';
    }

    return ColoredBox(
      color: ZipColors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.searchController,
                    focusNode: widget.searchFocus,
                    decoration: InputDecoration(
                      hintText: 'Search channels and shows',
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(left: 14, right: 8),
                        child: Icon(Icons.search, size: 19),
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 38),
                      suffixIcon: searching
                          ? IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: widget.searchController.clear,
                            )
                          : null,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: widget.showCategories ? 'Hide categories' : 'Show categories',
                  onPressed: widget.onToggleCategories,
                  icon: Icon(
                    widget.showCategories ? Icons.view_sidebar : Icons.view_sidebar_outlined,
                    size: 20,
                  ),
                ),
                IconButton(
                  tooltip: 'Hide channels (Ctrl+B)',
                  onPressed: widget.onHide,
                  icon: const Icon(Icons.keyboard_double_arrow_left, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                if (widget.showCategories) ...[
                  SizedBox(
                    width: widget.categoriesWidth,
                    child: Opacity(
                      opacity: searching ? 0.45 : 1,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
                        children: [
                          if (showRecents)
                            _CategoryTile(
                              icon: '🕘',
                              name: 'Recent',
                              count: live.recents.length,
                              selected: !searching && selectedId == recentCategoryId,
                              onTap: () => _pick(recentCategoryId),
                            ),
                          for (final c in categories)
                            _CategoryTile(
                              icon: c.icon,
                              name: c.name,
                              count: _catalog.channelsIn(c).length,
                              selected: !searching && selectedId == c.id,
                              onTap: () => _pick(c.id),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: Column(
                    children: [
                      if (!widget.showCategories && !searching)
                        _CategoryMenu(
                          title: title,
                          showRecents: showRecents,
                          categories: categories,
                          selectedId: selectedId,
                          onPick: _pick,
                        ),
                      if (feeds.isNotEmpty && !searching)
                        SizedBox(
                          height: 44,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            children: [
                              _FeedChip(
                                label: 'All',
                                selected: _feedId == null,
                                onTap: () => setState(() => _feedId = null),
                              ),
                              for (final f in feeds)
                                _FeedChip(
                                  label: f.label ?? f.name ?? f.id,
                                  selected: _feedId == f.id,
                                  onTap: () => setState(() => _feedId = f.id),
                                ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: channels.isEmpty
                            ? _Empty(
                                searching
                                    ? 'Nothing matches "$query".'
                                    : selectedId == CategoryIds.popular
                                    ? "Nobody's watching anything right now."
                                    : 'No channels here.',
                              )
                            : ListView.builder(
                                itemCount: channels.length,
                                itemExtent: 62,
                                itemBuilder: (context, index) {
                                  final channel = channels[index];
                                  return _ChannelRow(
                                    channel: channel,
                                    catalog: _catalog,
                                    selected: channel.id == live.current?.id,
                                    onTap: () => widget.onTune(channel, channels, title),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _pick(String id) {
    if (widget.searchController.text.isNotEmpty) widget.searchController.clear();
    widget.onSelectCategory(id);
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.icon,
    required this.name,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String? icon;
  final String name;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ZipTappable(
        onTap: onTap,
        color: selected ? ZipColors.selected : Colors.transparent,
        hoverColor: selected ? null : ZipColors.hover,
        child: ClipRRect(
          borderRadius: ZipRadius.smAll,
          child: SizedBox(
            height: 36,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: ZipMotion.fast,
                  width: 3,
                  color: selected ? ZipColors.accent : Colors.transparent,
                ),
                const SizedBox(width: 9),
                if (icon != null && icon!.isNotEmpty) ...[
                  Text(icon!, style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 7),
                ],
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: selected ? ZipColors.text : ZipColors.textSecondary,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                Text('$count', style: ZipText.mono(fontSize: 12)),
                const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Stands in for the category column when it is hidden.
class _CategoryMenu extends StatelessWidget {
  const _CategoryMenu({
    required this.title,
    required this.showRecents,
    required this.categories,
    required this.selectedId,
    required this.onPick,
  });

  final String title;
  final bool showRecents;
  final List<Category> categories;
  final String? selectedId;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Choose a category',
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 240, maxHeight: 520),
      onSelected: onPick,
      itemBuilder: (context) => [
        if (showRecents)
          CheckedPopupMenuItem(
            value: recentCategoryId,
            checked: selectedId == recentCategoryId,
            child: const Text('Recent'),
          ),
        for (final c in categories)
          CheckedPopupMenuItem(
            value: c.id,
            checked: selectedId == c.id,
            child: Text(c.icon == null || c.icon!.isEmpty ? c.name : '${c.icon}  ${c.name}'),
          ),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: ZipColors.line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const Icon(Icons.arrow_drop_down, color: ZipColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _FeedChip extends StatelessWidget {
  const _FeedChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _ChannelRow extends StatefulWidget {
  const _ChannelRow({
    required this.channel,
    required this.catalog,
    required this.selected,
    required this.onTap,
  });

  final Channel channel;
  final CatalogStore catalog;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  bool _hover = false;

  Color _stateColor(String state) => switch (state) {
    'running' || 'paused' => ZipColors.live,
    'retrying' => ZipColors.retrying,
    'unavailable' => ZipColors.offline,
    _ => ZipColors.textMuted,
  };

  Future<void> _toggleFavorite() async {
    final catalog = widget.catalog;
    final id = widget.channel.id;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await catalog.setFavorite(id, !catalog.isFavorite(id));
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text("Couldn't update favorites")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final catalog = widget.catalog;
    final text = Theme.of(context).textTheme;
    final now = channel.nowPlaying;
    final title = now?.title;
    final progress = nowPlayingProgress(now);
    final favorite = catalog.isFavorite(channel.id);
    final state = catalog.stateOf(channel);
    final viewers = catalog.viewerCount(channel.id);

    final selected = widget.selected;

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 1, 6, 1),
      child: ZipTappable(
        onTap: widget.onTap,
        onHover: (v) => setState(() => _hover = v),
        color: selected ? ZipColors.selected : Colors.transparent,
        hoverColor: selected ? null : ZipColors.hover,
        child: ClipRRect(
          borderRadius: ZipRadius.smAll,
          child: Row(
            children: [
              // Each channel keeps its own hue, as on the web viewer's tiles.
              Container(width: 4, color: channelStripe(channel.name)),
              const SizedBox(width: 10),
              SizedBox(
                width: 46,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: channel.number == null
                      ? const SizedBox.shrink()
                      : ChNumChip(channel.number!),
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge?.copyWith(
                        height: 1.25,
                        color: selected ? ZipColors.accentText : ZipColors.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (title != null && title.isNotEmpty)
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          height: 1.3,
                          color: ZipColors.textSecondary,
                        ),
                      ),
                    if (progress != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 5, right: 8),
                        child: ClipRRect(
                          borderRadius: ZipRadius.pillAll,
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 3,
                            backgroundColor: ZipColors.line,
                            color: ZipColors.accent,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (viewers != null && viewers > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.visibility_outlined, size: 13, color: ZipColors.textMuted),
                      const SizedBox(width: 3),
                      Text('$viewers', style: ZipText.mono(fontSize: 12)),
                    ],
                  ),
                ),
              Tooltip(
                message: state,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: _stateColor(state), shape: BoxShape.circle),
                ),
              ),
              SizedBox(
                width: 38,
                child: favorite || _hover
                    ? IconButton(
                        tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        onPressed: _toggleFavorite,
                        icon: Icon(
                          favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                          color: favorite ? ZipColors.accentText : ZipColors.textMuted,
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: ZipColors.textMuted),
        ),
      ),
    );
  }
}

/// How far through the current programme we are, 0–1, or null when unknown.
double? nowPlayingProgress(NowPlaying? now, [DateTime? at]) {
  final start = now?.start;
  final stop = now?.stop;
  if (start == null || stop == null || !stop.isAfter(start)) return null;
  final when = at ?? DateTime.now();
  final total = stop.difference(start).inSeconds;
  final done = when.difference(start).inSeconds;
  if (done < 0 || done > total) return null;
  return done / total;
}
