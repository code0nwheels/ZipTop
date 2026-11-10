import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/session/playback_session.dart';
import '../../theme.dart';
import 'channel_picker_dialog.dart';
import 'multiview_controller.dart';
import 'multiview_layout.dart';

/// Several channels on screen at once. Click a tile to hear it.
class MultiviewView extends StatelessWidget {
  const MultiviewView({
    super.key,
    required this.controller,
    required this.fullscreen,
    required this.onToggleFullscreen,
    required this.onInteraction,
  });

  final MultiviewController controller;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  /// Called after a click so the shell can take keyboard focus back.
  final VoidCallback onInteraction;

  Future<void> _add(BuildContext context) async {
    final channel = await ChannelPickerDialog.show(
      context,
      catalog: controller.catalog,
      title: 'Add a screen',
      excludeIds: {for (final t in controller.tiles) t.channel.id},
    );
    if (channel != null) controller.add(channel);
    onInteraction();
  }

  Future<void> _change(BuildContext context, MultiTile tile) async {
    final channel = await ChannelPickerDialog.show(
      context,
      catalog: controller.catalog,
      title: 'Change channel',
      excludeIds: {
        for (final t in controller.tiles)
          if (t != tile) t.channel.id,
      },
    );
    if (channel != null) controller.changeChannel(tile, channel);
    onInteraction();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final tiles = controller.tiles;
        final full = controller.fullTile;
        final shown = full == null ? tiles : [full];
        return ColoredBox(
          color: Colors.black,
          child: Column(
            children: [
              if (!fullscreen) _toolbar(context, tiles.length),
              Expanded(
                child: tiles.isEmpty
                    ? _empty(context)
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final rects = layoutTiles(
                            full == null ? controller.layout : MultiLayout.grid,
                            shown.length,
                            constraints.biggest,
                          );
                          return Stack(
                            children: [
                              for (var i = 0; i < shown.length; i++)
                                AnimatedPositioned(
                                  key: ValueKey(shown[i].id),
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOut,
                                  left: rects[i].left,
                                  top: rects[i].top,
                                  width: rects[i].width,
                                  height: rects[i].height,
                                  child: _Tile(
                                    controller: controller,
                                    tile: shown[i],
                                    selected: controller.selected == shown[i],
                                    isFull: full != null,
                                    onChange: () => _change(context, shown[i]),
                                    onAdd: controller.canAdd
                                        ? () => _add(context)
                                        : null,
                                    onInteraction: onInteraction,
                                  ),
                                ),
                              if (tiles.length == 1 && full == null)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 20,
                                  child: Center(
                                    child: FilledButton.tonalIcon(
                                      onPressed: () => _add(context),
                                      icon: const Icon(Icons.add),
                                      label: const Text('Add more screens'),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _toolbar(BuildContext context, int count) {
    return Container(
      color: ZipColors.background,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Text('Multiview', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 12),
          Text(
            '$count of $maxMultiviewTiles screens',
            style: const TextStyle(color: ZipColors.textMuted),
          ),
          const Spacer(),
          for (final layout in MultiLayout.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(layout.label),
                selected: controller.layout == layout,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: layout.availableFor(count)
                    ? (_) {
                        controller.setLayout(layout);
                        onInteraction();
                      }
                    : null,
              ),
            ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: controller.canAdd ? () => _add(context) : null,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add screen'),
          ),
          IconButton(
            tooltip: 'Full screen (F)',
            onPressed: onToggleFullscreen,
            icon: const Icon(Icons.fullscreen),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Watch up to 8 channels at once.',
            style: TextStyle(color: ZipColors.textSecondary, fontSize: 16),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _add(context),
            icon: const Icon(Icons.add),
            label: const Text('Add a screen'),
          ),
        ],
      ),
    );
  }
}

enum _TileAction { change, retry, pause, enlarge, full, add, remove }

class _Tile extends StatefulWidget {
  const _Tile({
    required this.controller,
    required this.tile,
    required this.selected,
    required this.isFull,
    required this.onChange,
    required this.onAdd,
    required this.onInteraction,
  });

  final MultiviewController controller;
  final MultiTile tile;
  final bool selected;
  final bool isFull;
  final VoidCallback onChange;
  final VoidCallback? onAdd;
  final VoidCallback onInteraction;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _hover = false;
  bool _menuOpen = false;

  void _run(_TileAction action) {
    final controller = widget.controller;
    final tile = widget.tile;
    switch (action) {
      case _TileAction.change:
        widget.onChange();
      case _TileAction.retry:
        controller.retry(tile);
      case _TileAction.pause:
        controller.togglePause(tile);
      case _TileAction.enlarge:
        controller.enlarge(tile);
      case _TileAction.full:
        controller.toggleFullTile(tile);
      case _TileAction.add:
        widget.onAdd?.call();
      case _TileAction.remove:
        controller.remove(tile);
    }
    widget.onInteraction();
  }

  List<PopupMenuEntry<_TileAction>> _menu() {
    final tile = widget.tile;
    final many = widget.controller.tiles.length > 1;
    return [
      const PopupMenuItem(
        value: _TileAction.change,
        child: Text('Change channel'),
      ),
      const PopupMenuItem(value: _TileAction.retry, child: Text('Retry')),
      PopupMenuItem(
        value: _TileAction.pause,
        child: Text(tile.paused ? 'Resume' : 'Pause'),
      ),
      if (many && !widget.isFull)
        const PopupMenuItem(value: _TileAction.enlarge, child: Text('Enlarge')),
      if (many)
        PopupMenuItem(
          value: _TileAction.full,
          child: Text(widget.isFull ? 'Back to all screens' : 'Show alone'),
        ),
      if (widget.onAdd != null)
        const PopupMenuItem(value: _TileAction.add, child: Text('Add screen')),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: _TileAction.remove,
        child: Text('Remove screen'),
      ),
    ];
  }

  Future<void> _contextMenu(Offset position) async {
    widget.controller.select(widget.tile);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<_TileAction>(
      context: context,
      color: ZipColors.surface,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: _menu(),
    );
    if (action != null) _run(action);
  }

  @override
  Widget build(BuildContext context) {
    final tile = widget.tile;
    final session = tile.session;
    final channel = tile.channel;

    String? message;
    var busy = false;
    if (tile.failure != null) {
      message = tile.failure;
    } else {
      switch (session.phase) {
        case SessionPhase.preparing:
          busy = true;
        case SessionPhase.failed:
          message = session.message ?? 'Could not start this channel.';
        case SessionPhase.streamLimit:
          message = session.message ?? 'Stream limit reached.';
        case SessionPhase.watchTimeUp:
          message = session.message ?? 'Watch time limit reached.';
        case SessionPhase.idle:
        case SessionPhase.playing:
          break;
      }
    }
    final warning = session.warningSeconds;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          widget.controller.select(tile);
          widget.onInteraction();
        },
        onDoubleTap: widget.controller.tiles.length > 1
            ? () => _run(_TileAction.full)
            : null,
        child: Listener(
          // Read straight from the pointer so a right-click never waits on,
          // or loses to, the tap and double-tap recognisers.
          onPointerDown: (event) {
            if (event.buttons & kSecondaryMouseButton != 0) {
              _contextMenu(event.position);
            }
          },
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              border: Border.all(
                width: 2,
                color:
                    widget.selected &&
                        !widget.isFull &&
                        widget.controller.tiles.length > 1
                    ? ZipColors.accent
                    : const Color(0xFF111111),
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(
                  // A rebuilt player needs a fresh video surface.
                  key: ObjectKey(tile.player),
                  controller: tile.player.controller,
                  controls: NoVideoControls,
                  fill: Colors.black,
                ),
                if (busy) const Center(child: CircularProgressIndicator()),
                if (message != null)
                  ColoredBox(
                    color: Colors.black54,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(message, textAlign: TextAlign.center),
                            const SizedBox(height: 10),
                            FilledButton.tonal(
                              onPressed: () {
                                if (session.phase == SessionPhase.watchTimeUp) {
                                  session.extendWatch();
                                }
                                _run(_TileAction.retry);
                              },
                              child: Text(
                                session.phase == SessionPhase.watchTimeUp
                                    ? 'Keep watching'
                                    : 'Retry',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (warning != null)
                  Center(
                    child: FilledButton(
                      onPressed: session.extendWatch,
                      child: Text('Still watching? ($warning s)'),
                    ),
                  ),
                Positioned(
                  left: 8,
                  bottom: 6,
                  right: 44,
                  child: Row(
                    children: [
                      Icon(
                        widget.selected ? Icons.volume_up : Icons.volume_off,
                        size: 16,
                        color: widget.selected
                            ? ZipColors.accent
                            : Colors.white54,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          [
                            if (channel.number != null) '${channel.number}',
                            channel.name,
                            if (tile.paused) 'Paused',
                          ].join('  ·  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(blurRadius: 6, color: Colors.black),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Always in the tree, only faded: the open menu takes the mouse
                // away from the tile, and a button removed at that moment would
                // drop the choice made in its menu.
                Positioned(
                  top: 4,
                  right: 4,
                  child: AnimatedOpacity(
                    opacity: _hover || _menuOpen ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: PopupMenuButton<_TileAction>(
                      tooltip: 'Screen options',
                      color: ZipColors.surface,
                      icon: const Icon(
                        Icons.more_vert,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                      ),
                      onOpened: () {
                        setState(() => _menuOpen = true);
                        widget.controller.select(tile);
                      },
                      onCanceled: () => setState(() => _menuOpen = false),
                      onSelected: (action) {
                        setState(() => _menuOpen = false);
                        _run(action);
                      },
                      itemBuilder: (_) => _menu(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
