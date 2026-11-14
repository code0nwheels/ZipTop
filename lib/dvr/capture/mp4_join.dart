import 'dart:convert';
import 'dart:typed_data';

/// Folds a separately delivered audio rendition into a recording, segment
/// by segment, so the file keeps its sound.
abstract interface class AudioJoiner {
  /// Whether any audio has been joined yet.
  bool get hasAudio;

  /// A video segment, adjusted to sit beside the joined audio.
  Uint8List video(Uint8List segment);

  /// An audio segment, ready to append; empty when nothing in it is usable.
  Uint8List audio(Uint8List segment);
}

/// One ISO BMFF box within a buffer.
typedef _Box = ({String type, int start, int header, int end});

/// The fMP4 counterpart of `TsAudioJoiner`: a video variant and an audio
/// rendition that each come as an init segment and `moof`/`mdat` fragments.
///
/// [join] builds one init segment whose `moov` carries both tracks, the
/// audio renumbered when its track ID clashes with the video's. Each audio
/// fragment is then appended with its `tfhd` pointing at that track. A
/// fragment's sample offsets are relative to its own `moof`, so a
/// `moof`+`mdat` pair can move into the file intact.
class Mp4AudioJoiner implements AudioJoiner {
  Mp4AudioJoiner._(this._audioTrackIn, this._audioTrackOut);

  final int _audioTrackIn;
  final int _audioTrackOut;
  bool _joined = false;

  /// The merged init segment and the joiner for the fragments, or null when
  /// either init segment is not a fragmented MP4 this can merge.
  static (Uint8List, Mp4AudioJoiner)? join(Uint8List videoInit, Uint8List audioInit) {
    final videoMoov = _find(_boxes(videoInit, 0, videoInit.length), 'moov');
    final audioMoov = _find(_boxes(audioInit, 0, audioInit.length), 'moov');
    if (videoMoov == null || audioMoov == null) return null;

    final videoChildren = _children(videoInit, videoMoov);
    final videoIds = <int>{
      for (final trak in videoChildren.where((b) => b.type == 'trak')) ?_trackId(videoInit, trak),
    };
    if (videoIds.isEmpty || _find(videoChildren, 'mvex') == null) return null;

    final audioChildren = _children(audioInit, audioMoov);
    _Box? audioTrak;
    for (final trak in audioChildren.where((b) => b.type == 'trak')) {
      if (_handler(audioInit, trak) == 'soun') {
        audioTrak = trak;
        break;
      }
    }
    if (audioTrak == null) return null;
    final audioIn = _trackId(audioInit, audioTrak);
    if (audioIn == null) return null;
    final audioMvex = _find(audioChildren, 'mvex');
    _Box? audioTrex;
    if (audioMvex != null) {
      for (final trex in _children(audioInit, audioMvex).where((b) => b.type == 'trex')) {
        if (_u32(audioInit, trex.start + trex.header + 4) == audioIn) audioTrex = trex;
      }
    }
    if (audioTrex == null) return null;

    final maxVideoId = videoIds.reduce((a, b) => a > b ? a : b);
    final audioOut = videoIds.contains(audioIn) ? maxVideoId + 1 : audioIn;

    // The audio trak and trex, renumbered.
    final trak = _copy(audioInit, audioTrak);
    final tkhd = _findPath(trak, ['tkhd']);
    if (tkhd == null) return null;
    final tkhdVersion = trak[tkhd.start + tkhd.header];
    _setU32(trak, tkhd.start + tkhd.header + (tkhdVersion == 1 ? 20 : 12), audioOut);
    final trex = _copy(audioInit, audioTrex);
    _setU32(trex, audioTrex.header + 4, audioOut);

    final moov = BytesBuilder(copy: false);
    for (final child in videoChildren) {
      switch (child.type) {
        case 'mvhd':
          final mvhd = _copy(videoInit, child);
          final at = child.header + (mvhd[child.header] == 1 ? 108 : 96); // next_track_ID
          if (at + 4 <= mvhd.length && _u32(mvhd, at) <= audioOut) _setU32(mvhd, at, audioOut + 1);
          moov.add(mvhd);
        case 'mvex':
          moov
            ..add(trak)
            ..add(
              _wrap('mvex', [
                Uint8List.sublistView(videoInit, child.start + child.header, child.end),
                trex,
              ]),
            );
        default:
          moov.add(Uint8List.sublistView(videoInit, child.start, child.end));
      }
    }

    final init = BytesBuilder(copy: false);
    for (final box in _boxes(videoInit, 0, videoInit.length)) {
      init.add(
        box.type == 'moov'
            ? _wrap('moov', [moov.takeBytes()])
            : Uint8List.sublistView(videoInit, box.start, box.end),
      );
    }
    return (init.takeBytes(), Mp4AudioJoiner._(audioIn, audioOut));
  }

  @override
  bool get hasAudio => _joined;

  /// Video fragments go in as they come.
  @override
  Uint8List video(Uint8List segment) => segment;

  /// The audio segment's `moof`/`mdat` pairs, renumbered to the joined
  /// track. Its `styp`, `sidx`, `mfra` and the like describe the rendition
  /// on its own and are left out.
  @override
  Uint8List audio(Uint8List segment) {
    final out = BytesBuilder(copy: false);
    final boxes = _boxes(segment, 0, segment.length).toList();
    for (var i = 0; i < boxes.length; i++) {
      if (boxes[i].type != 'moof') continue;
      final moof = _copy(segment, boxes[i]);
      for (final traf in _children(moof, (
        type: 'moof',
        start: 0,
        header: boxes[i].header,
        end: moof.length,
      ))) {
        if (traf.type != 'traf') continue;
        for (final tfhd in _children(moof, traf)) {
          final at = tfhd.start + tfhd.header + 4;
          if (tfhd.type == 'tfhd' && at + 4 <= tfhd.end && _u32(moof, at) == _audioTrackIn) {
            _setU32(moof, at, _audioTrackOut);
          }
        }
      }
      out.add(moof);
      // Everything up to its mdat stays with it, offsets and all.
      for (var j = i + 1; j < boxes.length; j++) {
        out.add(Uint8List.sublistView(segment, boxes[j].start, boxes[j].end));
        if (boxes[j].type == 'mdat') {
          i = j;
          break;
        }
      }
    }
    final bytes = out.takeBytes();
    if (bytes.isNotEmpty) _joined = true;
    return bytes;
  }

  /// Whether [bytes] starts like an ISO BMFF file or fragment.
  static bool looksLikeMp4(Uint8List bytes) {
    if (bytes.length < 8) return false;
    final type = ascii.decode(bytes.sublist(4, 8), allowInvalid: true);
    return const {'ftyp', 'styp', 'moof', 'moov', 'sidx', 'emsg', 'prft'}.contains(type);
  }

  // ---- boxes ----

  static Iterable<_Box> _boxes(Uint8List b, int start, int end) sync* {
    var p = start;
    while (p + 8 <= end) {
      var size = _u32(b, p);
      var header = 8;
      if (size == 1) {
        if (p + 16 > end) return;
        size = _u32(b, p + 8) * 0x100000000 + _u32(b, p + 12);
        header = 16;
      } else if (size == 0) {
        size = end - p;
      }
      if (size < header || p + size > end) return;
      yield (
        type: ascii.decode(b.sublist(p + 4, p + 8), allowInvalid: true),
        start: p,
        header: header,
        end: p + size,
      );
      p += size;
    }
  }

  static List<_Box> _children(Uint8List b, _Box box) =>
      _boxes(b, box.start + box.header, box.end).toList();

  static _Box? _find(Iterable<_Box> boxes, String type) {
    for (final box in boxes) {
      if (box.type == type) return box;
    }
    return null;
  }

  /// A box down [path] from the top of [b], which is itself one box.
  static _Box? _findPath(Uint8List b, List<String> path) {
    var box = (type: '', start: 0, header: _boxes(b, 0, b.length).first.header, end: b.length);
    for (final type in path) {
      final next = _find(_children(b, box), type);
      if (next == null) return null;
      box = next;
    }
    return box;
  }

  static int? _trackId(Uint8List b, _Box trak) {
    for (final child in _children(b, trak)) {
      if (child.type != 'tkhd') continue;
      final version = b[child.start + child.header];
      final at = child.start + child.header + (version == 1 ? 20 : 12);
      return at + 4 <= child.end ? _u32(b, at) : null;
    }
    return null;
  }

  static String? _handler(Uint8List b, _Box trak) {
    final mdia = _find(_children(b, trak), 'mdia');
    if (mdia == null) return null;
    final hdlr = _find(_children(b, mdia), 'hdlr');
    if (hdlr == null) return null;
    final at = hdlr.start + hdlr.header + 8; // version/flags, pre_defined
    return at + 4 <= hdlr.end ? ascii.decode(b.sublist(at, at + 4), allowInvalid: true) : null;
  }

  static Uint8List _copy(Uint8List b, _Box box) =>
      Uint8List.fromList(b.sublist(box.start, box.end));

  static Uint8List _wrap(String type, List<Uint8List> parts) {
    final length = 8 + parts.fold<int>(0, (n, p) => n + p.length);
    final out = Uint8List(length);
    _setU32(out, 0, length);
    out.setRange(4, 8, ascii.encode(type));
    var p = 8;
    for (final part in parts) {
      out.setRange(p, p + part.length, part);
      p += part.length;
    }
    return out;
  }

  static int _u32(Uint8List b, int p) => b[p] << 24 | b[p + 1] << 16 | b[p + 2] << 8 | b[p + 3];

  static void _setU32(Uint8List b, int p, int v) {
    b
      ..[p] = (v >> 24) & 0xFF
      ..[p + 1] = (v >> 16) & 0xFF
      ..[p + 2] = (v >> 8) & 0xFF
      ..[p + 3] = v & 0xFF;
  }
}
