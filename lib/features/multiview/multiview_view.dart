import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/session/playback_session.dart';
import '../../theme.dart';
import '../../ui/ch_num_chip.dart';
import '../../ui/segmented_pills.dart';
import '../../ui/zip_spinner.dart';
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
          color: ZipColors.page,
          child: Column(
            children: [
              if (!fullscreen) _toolbar(context, tiles.length),
              Expanded(
                child: tiles.isEmpty
                    ? _empty(context)
                    : Padding(
                        padding: EdgeInsets.all(fullscreen ? 0 : 6),
                        child: LayoutBuilder(
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
                                    child: Padding(
                                      padding: EdgeInsets.all(fullscreen ? 1 : 4),
                                      child: _Tile(
                                        controller: controller,
                                        tile: shown[i],
                                        selected: controller.selected == shown[i],
                                        isFull: full != null,
                                        rounded: !fullscreen,
                                        onChange: () => _change(context, shown[i]),
                                        onAdd: controller.canAdd
                                            ? () => _add(context)
                                            : null,
                                        onInteraction: onInteraction,
                                      ),
                                    ),
                                  ),
                                if (tiles.length == 1 && full == null)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 20,
                                    child: Center(
                                      child: FilledButton.icon(
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
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _toolbar(BuildContext context, int count) {
    return Container(
      decoration: const BoxDecoration(
        color: ZipColors.surface,
        border: Border(bottom: BorderSide(color: ZipColors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 10, 10, 10),
      child: Row(
        children: [
          Text('Multi-view', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 12),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$count',
                  style: ZipText.mono(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ZipColors.textSecondary,
                  ),
                ),
                TextSpan(
                  text: ' of $maxMultiviewTiles screens',
                  style: const TextStyle(color: ZipColors.textMuted, fontSize: 13),
                ),
              ],
            ),
          ),
          const Spacer(),
          SegmentedPills<MultiLayout>(
            values: MultiLayout.values,
            selected: controller.layout,
            label: (l) => l.label,
            enabled: (l) => l.availableFor(count),
            onSelected: (layout) {
              controller.setLayout(layout);
              onInteraction();
            },
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: controller.canAdd ? () => _add(context) : null,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add screen'),
          ),
          const SizedBox(width: 4),
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
          Text(
            'Watch up to $maxMultiviewTiles channels at once',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Click a screen to hear it. Right-click for more.',
            style: TextStyle(color: ZipColors.textSecondary, fontSize: 15),
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
    required this.rounded,
    required this.onChange,
    required this.onAdd,
    required this.onInteraction,
  });

  final MultiviewController controller;
  final MultiTile tile;
  final bool selected;
  final bool isFull;

  /// Rounded, gapped slots; full screen packs them square and tight.
  final bool rounded;
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
        case SessionPhase.notEntitled:
          message = session.message ?? "Your plan doesn't include this channel.";
        case SessionPhase.watchTimeUp:
          message = session.message ?? 'Watch time limit reached.';
        case SessionPhase.idle:
        case SessionPhase.playing:
          break;
      }
    }
    final warning = session.warningSeconds;
    final audible = widget.selected &&
        !widget.isFull &&
        widget.controller.tiles.length > 1;
    final radius = widget.rounded ? ZipRadius.mdAll : BorderRadius.zero;

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
          child: AnimatedContainer(
            duration: ZipMotion.fast,
            // The screen you hear gets an accent border and ring.
            foregroundDecoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                width: audible ? 2 : 1,
                color: audible ? ZipColors.accent : ZipColors.line,
              ),
            ),
            decoration: BoxDecoration(color: Colors.black, borderRadius: radius),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                KeyedSubtree(
                  // A rebuilt player needs a fresh video surface.
                  key: ObjectKey(tile.player),
                  child: tile.player.view(),
                ),
                if (busy) const Center(child: ZipSpinner()),
                if (message != null)
                  ColoredBox(
                    color: ZipColors.overlayPlayer,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              message,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 10),
                            FilledButton(
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
                // A soft scrim behind the options button, on hover only.
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 56,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _hover || _menuOpen ? 1 : 0,
                      duration: ZipMotion.fast,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xD9070C18), Colors.transparent],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 8,
                  bottom: 8,
                  right: 8,
                  child: Row(
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
                          decoration: const BoxDecoration(
                            color: ZipColors.overlayPill,
                            borderRadius: ZipRadius.pillAll,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                widget.selected ? Icons.volume_up : Icons.volume_off,
                                size: 15,
                                color: widget.selected
                                    ? ZipColors.accentText
                                    : ZipColors.textMuted,
                              ),
                              const SizedBox(width: 6),
                              if (channel.number != null) ...[
                                ChNumChip(channel.number!),
                                const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: Text(
                                  tile.paused ? '${channel.name}  ·  Paused' : channel.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: ZipColors.text,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
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
                    duration: ZipMotion.fast,
                    child: PopupMenuButton<_TileAction>(
                      tooltip: 'Screen options',
                      icon: const Icon(Icons.more_vert, color: ZipColors.text),
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
