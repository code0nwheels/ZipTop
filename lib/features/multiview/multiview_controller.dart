import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;
import 'package:media_kit/media_kit.dart';

import '../../core/api/api_config.dart';
import '../../core/api/streams_api.dart';
import '../../core/models/catalog.dart';
import '../../core/session/playback_session.dart';
import '../../core/stores/catalog_store.dart';
import '../../core/stores/settings_store.dart';
import '../../player/mpv_player.dart';
import 'multiview_layout.dart';

/// One screen in multiview: its own server session and its own mpv.
class MultiTile {
  MultiTile._(this.id, this.channel, this.session, this.player);

  final int id;
  Channel channel;
  final PlaybackSession session;
  MpvPlayer player;

  bool paused = false;

  /// Set when the stream cannot be shown at all (unsupported format).
  String? failure;

  String? _playingUrl;
  int _failures = 0;
  Duration _position = Duration.zero;
  bool _loadedCapped = false;
  Timer? _startTimer;
  Timer? _retryTimer;
  Timer? _errorTimer;
  Timer? _stallTimer;
  List<StreamSubscription<dynamic>> _subs = const [];
  VoidCallback? _sessionListener;
}

/// Up to eight channels at once. Audio follows the selected tile; the others
/// play muted and capped at 720p.
class MultiviewController extends ChangeNotifier {
  MultiviewController({
    required this.catalog,
    required this.settings,
    required this._api,
    required this._config,
    this.slots,
  }) : _layout = MultiLayout.byName(settings.multiviewLayout);

  static const unsupportedMessage = "This channel's stream format can't be played.";
  /// Small tiles take the best HLS variant at or under this, roughly 720p.
  static const tileBitrateCap = 4500000;
  static const startStagger = Duration(milliseconds: 200);
  static const rebuildEvery = 5;
  static const _errorGrace = Duration(seconds: 4);
  static const _stallLimit = Duration(seconds: 30);

  final CatalogStore catalog;
  final SettingsStore settings;
  final StreamsApi _api;
  final ApiConfig _config;

  /// Shared stream bookkeeping, so a tile never ends a stream that a
  /// recording is still using.
  final StreamSlots? slots;

  final _tiles = <MultiTile>[];
  MultiLayout _layout;
  int? _selectedId;
  int? _fullTileId;
  int _nextId = 1;
  bool _disposed = false;

  List<MultiTile> get tiles => List.unmodifiable(_tiles);
  MultiLayout get layout => _layout;
  bool get canAdd => _tiles.length < maxMultiviewTiles;
  bool get isOpen => _tiles.isNotEmpty;

  /// The tile whose audio is heard.
  MultiTile? get selected => _byId(_selectedId);

  /// A tile temporarily shown on its own, or null.
  MultiTile? get fullTile => _byId(_fullTileId);

  MultiTile? _byId(int? id) {
    for (final tile in _tiles) {
      if (tile.id == id) return tile;
    }
    return null;
  }

  /// Opens multiview with the screens used last time, or with [seed] alone.
  void enter({Channel? seed}) {
    if (_tiles.isNotEmpty) return;
    final restored = [
      for (final id in settings.multiviewIds)
        if (catalog.channelsById[id] != null) catalog.channelsById[id]!,
    ];
    final channels = restored.isNotEmpty ? restored : [?seed];
    for (final channel in channels.take(maxMultiviewTiles)) {
      _addTile(channel);
    }
    _selectedId = _tiles.isEmpty ? null : _tiles.first.id;
    _applyAudio();
    _changed();
  }

  void add(Channel channel) {
    if (!canAdd) return;
    final tile = _addTile(channel);
    _selectedId ??= tile.id;
    _afterStructureChange();
  }

  void changeChannel(MultiTile tile, Channel channel) {
    if (!_tiles.contains(tile) || tile.channel.id == channel.id) return;
    tile.channel = channel;
    tile.failure = null;
    tile.paused = false;
    tile._failures = 0;
    _cancelRecovery(tile);
    tile._playingUrl = null;
    unawaited(tile.player.stop());
    unawaited(tile.session.open(channel.id, iptv: channel.isIptv));
    _afterStructureChange();
  }

  void remove(MultiTile tile) {
    if (!_tiles.remove(tile)) return;
    unawaited(_release(tile));
    if (_fullTileId == tile.id) _fullTileId = null;
    if (_selectedId == tile.id) _selectedId = _tiles.isEmpty ? null : _tiles.first.id;
    _afterStructureChange();
  }

  void select(MultiTile tile) {
    if (_selectedId == tile.id) return;
    _selectedId = tile.id;
    _applyAudio();
    _changed();
  }

  /// Selects the tile [step] places along, wrapping.
  void selectRelative(int step) {
    if (_tiles.isEmpty) return;
    final index = _tiles.indexWhere((t) => t.id == _selectedId);
    select(_tiles[(index + step) % _tiles.length]);
  }

  void setLayout(MultiLayout layout) {
    if (_layout == layout) return;
    _layout = layout;
    settings.multiviewLayout = layout.name;
    _changed();
  }

  /// Makes [tile] the big one. From the grid this switches to Hero left.
  void enlarge(MultiTile tile) {
    if (!_tiles.remove(tile)) return;
    _tiles.insert(0, tile);
    if (_layout == MultiLayout.grid) {
      _layout = MultiLayout.heroLeft;
      settings.multiviewLayout = _layout.name;
    }
    select(tile);
    _afterStructureChange();
  }

  /// Shows [tile] alone, or goes back to the layout.
  void toggleFullTile(MultiTile tile) {
    _fullTileId = _fullTileId == tile.id ? null : tile.id;
    if (_fullTileId != null) {
      _selectedId = tile.id;
      // It was loaded at tile quality; load it again at the best there is.
      if (tile._loadedCapped && tile._playingUrl != null) {
        tile._playingUrl = null;
        unawaited(tile.session.reopen());
      }
    }
    _applyAudio();
    _changed();
  }

  void exitFullTile() {
    if (_fullTileId == null) return;
    _fullTileId = null;
    _changed();
  }

  void togglePause(MultiTile tile) {
    tile.paused = !tile.paused;
    unawaited(tile.paused ? tile.player.player.pause() : tile.player.player.play());
    _changed();
  }

  void retry(MultiTile tile) {
    tile.failure = null;
    tile._failures = 0;
    _cancelRecovery(tile);
    tile._playingUrl = null;
    if (tile.session.streamId == tile.channel.id) {
      unawaited(tile.session.reopen());
    } else {
      unawaited(tile.session.open(tile.channel.id, iptv: tile.channel.isIptv));
    }
    _changed();
  }

  /// Re-applies the volume after the viewer changes it.
  void refreshAudio() => _applyAudio();

  /// Ends every session and frees every player. The screen list is kept in
  /// settings so multiview reopens the same way.
  Future<void> closeAll() async {
    final closing = [..._tiles];
    _tiles.clear();
    _selectedId = null;
    _fullTileId = null;
    _changed();
    await Future.wait([for (final tile in closing) _release(tile)]);
  }

  MultiTile _addTile(Channel channel) {
    final tile = MultiTile._(
      _nextId++,
      channel,
      PlaybackSession(_api, slots: slots),
      MpvPlayer(config: _config, tuning: PlayerTuning.tile),
    );
    tile._sessionListener = () => _onSession(tile);
    tile.session.addListener(tile._sessionListener!);
    _subscribe(tile);
    // Staggered so several tiles don't hit the server and decoder at once.
    final slot = _tiles.length;
    _tiles.add(tile);
    tile._startTimer = Timer(startStagger * slot, () {
      if (_tiles.contains(tile)) {
        unawaited(tile.session.open(tile.channel.id, iptv: tile.channel.isIptv));
      }
    });
    return tile;
  }

  void _subscribe(MultiTile tile) {
    final player = tile.player.player;
    tile._subs = [
      player.stream.completed.listen((done) {
        if (done) _recover(tile);
      }),
      player.stream.error.listen((message) => _onError(tile, message)),
      player.stream.position.listen((p) {
        // Real progress means the stream is healthy again.
        if (p > tile._position + const Duration(seconds: 2)) {
          tile._position = p;
          tile._failures = 0;
          tile._errorTimer?.cancel();
        }
      }),
      player.stream.buffering.listen((buffering) {
        tile._stallTimer?.cancel();
        if (buffering && tile._playingUrl != null) {
          tile._stallTimer = Timer(_stallLimit, () => _recover(tile));
        }
      }),
    ];
  }

  void _onSession(MultiTile tile) {
    if (!_tiles.contains(tile)) return;
    final session = tile.session;
    final url = session.url;
    if (session.phase == SessionPhase.playing && url != null) {
      if (url != tile._playingUrl) {
        tile._playingUrl = url;
        tile._position = Duration.zero;
        unawaited(_start(tile, url));
      }
    } else if (session.phase != SessionPhase.preparing) {
      _cancelRecovery(tile);
      if (tile._playingUrl != null) {
        tile._playingUrl = null;
        unawaited(tile.player.stop());
      }
    }
    _changed();
  }

  Future<void> _start(MultiTile tile, String url) async {
    final player = tile.player;
    final playable = await player.canPlay(url);
    if (_disposed || tile._playingUrl != url || tile.player != player) return;
    if (!playable) {
      tile._playingUrl = null;
      tile.failure = unsupportedMessage;
      await tile.session.close();
      _changed();
      return;
    }
    // The variant is chosen as the stream opens; switching afterwards makes
    // the player load it all over again.
    final capped = _tiles.length > 1 && _fullTileId != tile.id;
    tile._loadedCapped = capped && !isDashUrl(url);
    await player.setHlsBitrateCap(capped ? tileBitrateCap : null);
    await _setAudio(tile);
    if (_disposed || tile._playingUrl != url || tile.player != player) return;
    await player.play(url);
    // Opening a stream can put the audio track back to automatic.
    if (_tiles.contains(tile) && tile.player == player) await _setAudio(tile);
    if (tile.paused) await player.player.pause();
  }

  void _onError(MultiTile tile, String message) {
    if (tile._playingUrl == null || !isReloadableError(message)) return;
    final mark = tile._position;
    tile._errorTimer?.cancel();
    tile._errorTimer = Timer(_errorGrace, () {
      // Still loading is the stall timer's business, not an error.
      if (tile._position == mark && !tile.player.player.state.buffering) _recover(tile);
    });
  }

  /// Asks for a new URL after a growing wait (2 s doubling to 32 s). Every
  /// fifth failure in a row also replaces the tile's player.
  void _recover(MultiTile tile) {
    if (tile._playingUrl == null || tile._retryTimer?.isActive == true) return;
    if (!_tiles.contains(tile)) return;
    final seconds = (2 << tile._failures.clamp(0, 4)).clamp(2, 32);
    tile._failures++;
    final channelId = tile.channel.id;
    tile._retryTimer = Timer(Duration(seconds: seconds), () {
      if (_disposed || !_tiles.contains(tile) || tile.channel.id != channelId) return;
      tile._playingUrl = null;
      if (tile._failures % rebuildEvery == 0) _rebuildPlayer(tile);
      unawaited(tile.session.reopen());
    });
  }

  void _rebuildPlayer(MultiTile tile) {
    for (final sub in tile._subs) {
      unawaited(sub.cancel());
    }
    final old = tile.player;
    tile.player = MpvPlayer(config: _config, tuning: PlayerTuning.tile);
    _subscribe(tile);
    unawaited(old.dispose());
    _changed();
  }

  void _applyAudio() {
    for (final tile in _tiles) {
      unawaited(_setAudio(tile));
    }
  }

  /// Only the selected tile decodes and outputs sound; the rest have their
  /// audio track switched off, so they never open the sound device.
  Future<void> _setAudio(MultiTile tile) async {
    final player = tile.player.player;
    if (tile.id == _selectedId) {
      await player.setVolume(settings.volume);
      await player.setAudioTrack(AudioTrack.auto());
    } else {
      await player.setAudioTrack(AudioTrack.no());
    }
  }

  void _cancelRecovery(MultiTile tile) {
    tile._retryTimer?.cancel();
    tile._errorTimer?.cancel();
    tile._stallTimer?.cancel();
  }

  Future<void> _release(MultiTile tile) async {
    tile._startTimer?.cancel();
    _cancelRecovery(tile);
    for (final sub in tile._subs) {
      unawaited(sub.cancel());
    }
    final listener = tile._sessionListener;
    if (listener != null) tile.session.removeListener(listener);
    unawaited(tile.player.stop());
    try {
      await tile.session.close().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Best effort; the server times the session out anyway.
    }
    tile.session.dispose();
    await tile.player.dispose();
  }

  void _afterStructureChange() {
    settings.multiviewIds = [for (final tile in _tiles) tile.channel.id];
    _applyAudio();
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final tile in [..._tiles]) {
      unawaited(_release(tile));
    }
    _tiles.clear();
    super.dispose();
  }
}
