import 'dart:convert';
import 'dart:typed_data';

import 'mp4_join.dart';

/// One elementary stream of the joined audio, as the video's PMT lists it.
class _AudioStream {
  _AudioStream(this.pid, this.streamType, this.descriptors);
  final int pid;
  final int streamType;
  final Uint8List descriptors;
}

/// One audio frame found in a packed audio segment.
typedef _Frame = ({int size, int samples, int rate, int streamType, bool dependent});

/// Folds an HLS audio rendition, delivered as its own playlist, into the
/// video's MPEG-TS so a recording stays one file with its sound.
///
/// Surround channels usually come this way: the video variant's segments
/// carry no audio, and the 5.1 track is a separate `#EXT-X-MEDIA` rendition.
/// Both share the stream's 90 kHz clock, so the audio's own timestamps keep
/// it in sync however the segments are interleaved in the file.
///
/// Audio segments may be MPEG-TS, whose audio packets are moved to their own
/// PIDs, or packed audio (ADTS AAC, AC-3, E-AC-3 behind an ID3 timestamp),
/// which is wrapped in PES packets. The audio streams are then added to every
/// PMT of the video so players find them.
class TsAudioJoiner implements AudioJoiner {
  static const packetSize = 188;

  /// Output PIDs for the audio, clear of what HLS packagers use for video.
  static const firstAudioPid = 0x1F00;

  final _streams = <_AudioStream>[];
  final _continuity = <int, int>{};

  /// Input PID of an audio TS segment's stream → its output PID.
  final _audioPids = <int, int>{};
  int? _videoPmtPid;
  int? _audioPmtPid;

  /// Where the next packed segment starts when it carries no timestamp.
  int? _nextPts;

  @override
  bool get hasAudio => _streams.isNotEmpty;

  /// [segment] of video, with the joined audio listed in its PMTs.
  @override
  Uint8List video(Uint8List segment) {
    if (!_isTransportStream(segment)) return segment;
    Uint8List? out;
    for (var i = 0; i + packetSize <= segment.length; i += packetSize) {
      if (segment[i] != 0x47) break;
      if (!_unitStart(segment, i)) continue;
      final pid = _pid(segment, i);
      if (pid == 0) {
        _videoPmtPid = _pmtPidFromPat(segment, i) ?? _videoPmtPid;
      } else if (pid == _videoPmtPid && _streams.isNotEmpty) {
        final packet = _withAudioInPmt(segment, i);
        if (packet != null) {
          out ??= Uint8List.fromList(segment);
          out.setRange(i, i + packetSize, packet);
        }
      }
    }
    return out ?? segment;
  }

  /// [segment] of audio as TS packets on the joined audio PIDs; empty when
  /// nothing in it can be used.
  @override
  Uint8List audio(Uint8List segment) =>
      _isTransportStream(segment) ? _audioFromTs(segment) : _audioFromPacked(segment);

  // ---- audio delivered as MPEG-TS ----

  Uint8List _audioFromTs(Uint8List segment) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i + packetSize <= segment.length; i += packetSize) {
      if (segment[i] != 0x47) break;
      final pid = _pid(segment, i);
      if (pid == 0) {
        if (_unitStart(segment, i)) _audioPmtPid = _pmtPidFromPat(segment, i) ?? _audioPmtPid;
        continue;
      }
      if (pid == _audioPmtPid) {
        if (_unitStart(segment, i)) _learnAudioPmt(segment, i);
        continue;
      }
      final outPid = _audioPids[pid];
      if (outPid == null) continue;
      final packet = Uint8List.fromList(segment.sublist(i, i + packetSize));
      packet[1] = (packet[1] & 0xE0) | (outPid >> 8);
      packet[2] = outPid & 0xFF;
      out.add(packet);
    }
    return out.takeBytes();
  }

  void _learnAudioPmt(Uint8List b, int i) {
    final s = _sectionStart(b, i);
    if (s == null || b[s] != 0x02) return;
    var index = 0;
    for (final es in _pmtStreams(b, s, i + packetSize)) {
      if (_notAudio.contains(es.streamType)) continue;
      final outPid = firstAudioPid + index++;
      _audioPids[es.pid] = outPid;
      if (!_streams.any((a) => a.pid == outPid)) {
        _streams.add(_AudioStream(outPid, es.streamType, es.descriptors));
      }
    }
  }

  /// Stream types an audio rendition may carry that are not its audio:
  /// video, ID3 timed metadata, SCTE-35, private sections and DSM-CC.
  static const _notAudio = {0x01, 0x02, 0x05, 0x0B, 0x0C, 0x0D, 0x10, 0x15, 0x1B, 0x24, 0x42, 0x86};

  // ---- packed audio ----

  Uint8List _audioFromPacked(Uint8List segment) {
    var pos = 0;
    int? stamp;
    // ID3 tags lead a packed segment; the Apple PRIV frame in one of them
    // holds the timestamp of the first audio frame.
    while (segment.length - pos >= 10 &&
        segment[pos] == 0x49 && // I
        segment[pos + 1] == 0x44 && // D
        segment[pos + 2] == 0x33) {
      // 3
      final size =
          (segment[pos + 6] & 0x7F) << 21 |
          (segment[pos + 7] & 0x7F) << 14 |
          (segment[pos + 8] & 0x7F) << 7 |
          (segment[pos + 9] & 0x7F);
      final footer = segment[pos + 5] & 0x10 != 0 ? 10 : 0;
      final end = pos + 10 + size + footer;
      stamp ??= _id3Timestamp(segment, pos + 10, end > segment.length ? segment.length : end);
      pos = end;
    }
    final base = stamp ?? _nextPts;
    if (base == null) return Uint8List(0);

    final out = BytesBuilder(copy: false);
    final pending = BytesBuilder(copy: false);
    var pendingUnits = 0;
    var pendingPts = base;
    var samples = 0.0; // in 90 kHz ticks since [base]
    _AudioStream? stream;

    void flush() {
      final s = stream;
      if (pending.isEmpty || s == null) return;
      final streamId = s.streamType == 0x0F ? 0xC0 : 0xBD;
      out.add(_packetize(s.pid, _pes(streamId, pendingPts, pending.takeBytes())));
      pendingUnits = 0;
    }

    while (pos + 7 <= segment.length) {
      final frame = _frameAt(segment, pos);
      if (frame == null) {
        pos++; // Not a frame header: resynchronise.
        continue;
      }
      if (pos + frame.size > segment.length) break;
      stream ??= _packedStream(frame.streamType);
      // A dependent E-AC-3 substream belongs to the frame before it.
      if (!frame.dependent) {
        if (pendingUnits == 4) flush();
        if (pendingUnits == 0) pendingPts = (base + samples.round()) & _ptsMask;
        pendingUnits++;
        samples += frame.samples * 90000 / frame.rate;
      }
      pending.add(Uint8List.sublistView(segment, pos, pos + frame.size));
      pos += frame.size;
    }
    flush();
    _nextPts = (base + samples.round()) & _ptsMask;
    return out.takeBytes();
  }

  _AudioStream _packedStream(int streamType) {
    for (final s in _streams) {
      if (s.streamType == streamType) return s;
    }
    final descriptor = switch (streamType) {
      0x81 => _registration('AC-3'),
      0x87 => _registration('EAC3'),
      _ => Uint8List(0),
    };
    final stream = _AudioStream(firstAudioPid + _streams.length, streamType, descriptor);
    _streams.add(stream);
    return stream;
  }

  static Uint8List _registration(String id) => Uint8List.fromList([0x05, 4, ...ascii.encode(id)]);

  static const _ptsMask = 0x1FFFFFFFF;
  static final _priv = ascii.encode('com.apple.streaming.transportStreamTimestamp');

  /// The 33-bit timestamp in an ID3 tag's body, or null when it has none.
  static int? _id3Timestamp(Uint8List b, int from, int to) {
    outer:
    for (var i = from; i + _priv.length + 9 <= to; i++) {
      for (var j = 0; j < _priv.length; j++) {
        if (b[i + j] != _priv[j]) continue outer;
      }
      final v = i + _priv.length + 1; // past the owner's NUL
      return (b[v + 3] & 0x01) * 0x100000000 +
          (b[v + 4] << 24 | b[v + 5] << 16 | b[v + 6] << 8 | b[v + 7]);
    }
    return null;
  }

  static const _adtsRates = [
    96000,
    88200,
    64000,
    48000,
    44100,
    32000,
    24000,
    22050,
    16000,
    12000,
    11025,
    8000,
  ];
  static const _ac3Kbps = [
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    160,
    192,
    224,
    256,
    320,
    384,
    448,
    512,
    576,
    640,
  ];
  static const _ac3Rates = [48000, 44100, 32000];

  /// The ADTS, AC-3 or E-AC-3 frame whose header starts at [p], if any.
  static _Frame? _frameAt(Uint8List b, int p) {
    if (b[p] == 0xFF && b[p + 1] & 0xF6 == 0xF0) {
      final size = (b[p + 3] & 0x03) << 11 | b[p + 4] << 3 | b[p + 5] >> 5;
      final rateIndex = (b[p + 2] >> 2) & 0x0F;
      if (size < 7 || rateIndex >= _adtsRates.length) return null;
      return (
        size: size,
        samples: 1024 * ((b[p + 6] & 0x03) + 1),
        rate: _adtsRates[rateIndex],
        streamType: 0x0F,
        dependent: false,
      );
    }
    if (b[p] != 0x0B || b[p + 1] != 0x77) return null;
    final bsid = b[p + 5] >> 3;
    if (bsid <= 10) {
      final fscod = b[p + 4] >> 6;
      final code = b[p + 4] & 0x3F;
      if (fscod == 3 || code >= 38) return null;
      final kbps = _ac3Kbps[code >> 1];
      final words = switch (fscod) {
        0 => kbps * 2,
        1 => kbps * 96000 ~/ 44100 + (code & 1),
        _ => kbps * 3,
      };
      return (
        size: words * 2,
        samples: 1536,
        rate: _ac3Rates[fscod],
        streamType: 0x81,
        dependent: false,
      );
    }
    if (bsid <= 16) {
      final size = ((b[p + 2] & 0x07) << 8 | b[p + 3]) * 2 + 2;
      final fscod = b[p + 4] >> 6;
      final int rate;
      final int blocks;
      if (fscod == 3) {
        final reduced = (b[p + 4] >> 4) & 0x03;
        if (reduced == 3) return null;
        rate = const [24000, 22050, 16000][reduced];
        blocks = 6;
      } else {
        rate = _ac3Rates[fscod];
        blocks = const [1, 2, 3, 6][(b[p + 4] >> 4) & 0x03];
      }
      return (
        size: size,
        samples: blocks * 256,
        rate: rate,
        streamType: 0x87,
        dependent: b[p + 2] >> 6 == 1,
      );
    }
    return null;
  }

  /// A PES packet with a presentation timestamp.
  static Uint8List _pes(int streamId, int pts, Uint8List payload) {
    final out = Uint8List(14 + payload.length);
    final length = payload.length + 8;
    out
      ..[2] = 1
      ..[3] = streamId
      ..[4] = length > 0xFFFF ? 0 : length >> 8
      ..[5] = length > 0xFFFF ? 0 : length & 0xFF
      ..[6] =
          0x84 // data aligned
      ..[7] =
          0x80 // PTS only
      ..[8] = 5
      ..[9] = 0x21 | ((pts >> 29) & 0x0E)
      ..[10] = (pts >> 22) & 0xFF
      ..[11] = ((pts >> 14) & 0xFE) | 1
      ..[12] = (pts >> 7) & 0xFF
      ..[13] = ((pts << 1) & 0xFE) | 1
      ..setRange(14, out.length, payload);
    return out;
  }

  /// [pes] cut into TS packets on [pid], the last one stuffed to size.
  Uint8List _packetize(int pid, Uint8List pes) {
    final count = (pes.length + 183) ~/ 184;
    final out = Uint8List(count * packetSize);
    var offset = 0;
    for (var n = 0; n < count; n++) {
      final p = n * packetSize;
      final cc = _continuity[pid] = ((_continuity[pid] ?? -1) + 1) & 0x0F;
      final remaining = pes.length - offset;
      out
        ..[p] = 0x47
        ..[p + 1] = (n == 0 ? 0x40 : 0) | (pid >> 8)
        ..[p + 2] = pid & 0xFF;
      var q = p + 4;
      if (remaining >= 184) {
        out[p + 3] = 0x10 | cc;
      } else {
        out[p + 3] = 0x30 | cc;
        final stuffing = 184 - remaining;
        out[q] = stuffing - 1; // adaptation_field_length
        if (stuffing > 1) {
          out[q + 1] = 0; // no flags
          out.fillRange(q + 2, q + stuffing, 0xFF);
        }
        q += stuffing;
      }
      final take = remaining < 184 ? remaining : 184;
      out.setRange(q, q + take, pes, offset);
      offset += take;
    }
    return out;
  }

  // ---- PSI ----

  /// The video PMT packet at [i] with the audio streams added, or null when
  /// it already lists them or cannot safely be rewritten.
  Uint8List? _withAudioInPmt(Uint8List b, int i) {
    final s = _sectionStart(b, i);
    final end = i + packetSize;
    if (s == null || s + 12 > end || b[s] != 0x02) return null;
    final length = (b[s + 1] & 0x0F) << 8 | b[s + 2];
    // Only a PMT that fits in this one packet, which is every HLS PMT seen.
    if (s + 3 + length > end || length < 13) return null;
    final listed = {for (final es in _pmtStreams(b, s, end)) es.pid};
    final extra = BytesBuilder();
    for (final a in _streams) {
      if (listed.contains(a.pid)) continue;
      extra.add([
        a.streamType,
        0xE0 | a.pid >> 8,
        a.pid & 0xFF,
        0xF0 | a.descriptors.length >> 8,
        a.descriptors.length & 0xFF,
        ...a.descriptors,
      ]);
    }
    if (extra.isEmpty) return null;
    final newLength = length + extra.length;
    if (s + 3 + newLength > end) return null;

    final bodyEnd = s + 3 + length - 4; // before the CRC
    final section = Uint8List(3 + newLength)
      ..setRange(0, bodyEnd - s, b, s)
      ..setRange(bodyEnd - s, 3 + newLength - 4, extra.takeBytes());
    section
      ..[1] = (b[s + 1] & 0xF0) | newLength >> 8
      ..[2] = newLength & 0xFF;
    final crc = crc32Mpeg(section, 0, section.length - 4);
    section
      ..[section.length - 4] = crc >> 24
      ..[section.length - 3] = (crc >> 16) & 0xFF
      ..[section.length - 2] = (crc >> 8) & 0xFF
      ..[section.length - 1] = crc & 0xFF;

    final packet = Uint8List.fromList(b.sublist(i, end));
    packet
      ..setRange(s - i, s - i + section.length, section)
      ..fillRange(s - i + section.length, packetSize, 0xFF);
    return packet;
  }

  static Iterable<({int streamType, int pid, Uint8List descriptors})> _pmtStreams(
    Uint8List b,
    int s,
    int end,
  ) sync* {
    if (s + 12 > end) return;
    final length = (b[s + 1] & 0x0F) << 8 | b[s + 2];
    final sectionEnd = s + 3 + length - 4;
    final infoLength = (b[s + 10] & 0x0F) << 8 | b[s + 11];
    var k = s + 12 + infoLength;
    while (k + 5 <= sectionEnd && k + 5 <= end) {
      final esInfo = (b[k + 3] & 0x0F) << 8 | b[k + 4];
      if (k + 5 + esInfo > end) return;
      yield (
        streamType: b[k],
        pid: (b[k + 1] & 0x1F) << 8 | b[k + 2],
        descriptors: Uint8List.fromList(b.sublist(k + 5, k + 5 + esInfo)),
      );
      k += 5 + esInfo;
    }
  }

  static int? _pmtPidFromPat(Uint8List b, int i) {
    final s = _sectionStart(b, i);
    final end = i + packetSize;
    if (s == null || s + 8 > end || b[s] != 0x00) return null;
    final length = (b[s + 1] & 0x0F) << 8 | b[s + 2];
    final entriesEnd = s + 3 + length - 4;
    for (var k = s + 8; k + 4 <= entriesEnd && k + 4 <= end; k += 4) {
      final program = b[k] << 8 | b[k + 1];
      if (program != 0) return (b[k + 2] & 0x1F) << 8 | b[k + 3];
    }
    return null;
  }

  /// Where the PSI section starts in the packet at [i], past the
  /// adaptation field and pointer field.
  static int? _sectionStart(Uint8List b, int i) {
    final control = (b[i + 3] >> 4) & 0x03;
    if (control & 0x01 == 0) return null;
    var p = i + 4;
    if (control & 0x02 != 0) p += 1 + b[p];
    if (p >= i + packetSize) return null;
    final s = p + 1 + b[p];
    return s < i + packetSize ? s : null;
  }

  static int _pid(Uint8List b, int i) => (b[i + 1] & 0x1F) << 8 | b[i + 2];
  static bool _unitStart(Uint8List b, int i) => b[i + 1] & 0x40 != 0;

  static bool _isTransportStream(Uint8List b) =>
      b.length >= packetSize &&
      b[0] == 0x47 &&
      (b.length < 2 * packetSize || b[packetSize] == 0x47);

  /// The CRC-32 that MPEG-TS sections carry (polynomial 0x04C11DB7, no
  /// reflection).
  static int crc32Mpeg(Uint8List data, int from, int to) {
    var crc = 0xFFFFFFFF;
    for (var i = from; i < to; i++) {
      crc ^= data[i] << 24;
      for (var bit = 0; bit < 8; bit++) {
        crc = crc & 0x80000000 != 0
            ? ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            : (crc << 1) & 0xFFFFFFFF;
      }
    }
    return crc;
  }
}
