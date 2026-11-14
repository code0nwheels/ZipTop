import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:ziptop/dvr/capture/hls_capture.dart';
import 'package:ziptop/dvr/capture/m3u8_parser.dart';
import 'package:ziptop/dvr/capture/mp4_join.dart';
import 'package:ziptop/dvr/capture/ts_join.dart';
import 'package:ziptop/dvr/models.dart';

class MemorySink implements CaptureSink {
  final _bytes = BytesBuilder();
  int? free;

  String get text => utf8.decode(_bytes.toBytes());
  Uint8List get bytes => _bytes.toBytes();

  @override
  int get bytesWritten => _bytes.length;

  @override
  Future<void> write(List<int> bytes) async => _bytes.add(bytes);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  int? freeBytes() => free;
}

Uint8List encryptAes128(List<int> plain, Uint8List key, Uint8List iv) {
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
      true,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
        null,
      ),
    );
  return cipher.process(Uint8List.fromList(plain));
}

// ---- MPEG-TS building and reading for the audio-join tests ----

Uint8List tsPacket(int pid, List<int> payload, {bool start = false, int cc = 0}) {
  final p = Uint8List(188)..fillRange(0, 188, 0xFF);
  p
    ..[0] = 0x47
    ..[1] = (start ? 0x40 : 0) | pid >> 8
    ..[2] = pid & 0xFF
    ..[3] = 0x10 | cc
    ..setRange(4, 4 + payload.length, payload);
  return p;
}

/// A PSI packet: pointer field, [section] and its CRC.
Uint8List psiPacket(int pid, List<int> section) {
  final body = Uint8List.fromList(section);
  final crc = TsAudioJoiner.crc32Mpeg(body, 0, body.length);
  return tsPacket(pid, [0, ...body, crc >> 24, (crc >> 16) & 0xFF, (crc >> 8) & 0xFF, crc & 0xFF],
      start: true);
}

Uint8List patPacket(int pmtPid) =>
    psiPacket(0, [0x00, 0xB0, 13, 0, 1, 0xC1, 0, 0, 0, 1, 0xE0 | pmtPid >> 8, pmtPid & 0xFF]);

Uint8List pmtPacket(int pmtPid, int pcrPid, List<(int, int, List<int>)> streams) {
  final es = [
    for (final (type, pid, desc) in streams) ...[
      type, 0xE0 | pid >> 8, pid & 0xFF, 0xF0 | desc.length >> 8, desc.length & 0xFF, ...desc, //
    ],
  ];
  final length = 9 + es.length + 4;
  return psiPacket(pmtPid, [
    0x02, 0xB0 | length >> 8, length & 0xFF, 0, 1, 0xC1, 0, 0, //
    0xE0 | pcrPid >> 8, pcrPid & 0xFF, 0xF0, 0, ...es,
  ]);
}

Uint8List segmentOf(List<Uint8List> packets) =>
    Uint8List.fromList([for (final p in packets) ...p]);

/// A video segment: PAT, PMT (H.264 on 0x100) and one marked video packet.
Uint8List videoSegment(int n) => segmentOf([
      patPacket(0x1000),
      pmtPacket(0x1000, 0x100, [(0x1B, 0x100, [])]),
      tsPacket(0x100, [0, 0, 1, 0xE0, 0x56, n], start: true),
    ]);

/// An audio segment: PAT, PMT (AC-3 on 0x100, the same PID as the video's)
/// and one marked audio packet.
Uint8List audioSegment(int n) => segmentOf([
      patPacket(0x1000),
      pmtPacket(0x1000, 0x100, [
        (0x81, 0x100, [0x0A, 4, 0x65, 0x6E, 0x67, 0]),
      ]),
      tsPacket(0x100, [0, 0, 1, 0xBD, 0x41, n], start: true),
    ]);

typedef Es = ({int type, int pid, List<int> descriptors});

class TsInfo {
  final pidPackets = <int, List<Uint8List>>{};
  List<Es> pmt = const [];
  bool crcOk = true;
}

TsInfo readTs(Uint8List bytes) {
  final info = TsInfo();
  int? pmtPid;
  for (var i = 0; i + 188 <= bytes.length; i += 188) {
    expect(bytes[i], 0x47, reason: 'sync byte at $i');
    final pid = (bytes[i + 1] & 0x1F) << 8 | bytes[i + 2];
    final packet = bytes.sublist(i, i + 188);
    info.pidPackets.putIfAbsent(pid, () => []).add(packet);
    if (bytes[i + 1] & 0x40 == 0) continue;
    final s = i + 5 + bytes[i + 4];
    final length = (bytes[s + 1] & 0x0F) << 8 | bytes[s + 2];
    if (pid == 0) {
      pmtPid = (bytes[s + 10] & 0x1F) << 8 | bytes[s + 11];
    } else if (pid == pmtPid) {
      final crcAt = s + 3 + length - 4;
      final crc = bytes[crcAt] << 24 | bytes[crcAt + 1] << 16 | bytes[crcAt + 2] << 8 | bytes[crcAt + 3];
      if (TsAudioJoiner.crc32Mpeg(bytes, s, crcAt) != crc) info.crcOk = false;
      final streams = <Es>[];
      var k = s + 12 + ((bytes[s + 10] & 0x0F) << 8 | bytes[s + 11]);
      while (k < crcAt) {
        final n = (bytes[k + 3] & 0x0F) << 8 | bytes[k + 4];
        streams.add((
          type: bytes[k],
          pid: (bytes[k + 1] & 0x1F) << 8 | bytes[k + 2],
          descriptors: bytes.sublist(k + 5, k + 5 + n),
        ));
        k += 5 + n;
      }
      info.pmt = streams;
    }
  }
  return info;
}

/// The PTS of the PES starting in [packet].
int ptsOf(Uint8List packet) {
  var p = 4;
  if (packet[3] & 0x20 != 0) p += 1 + packet[4];
  final b = packet.sublist(p + 9, p + 14);
  return (b[0] >> 1 & 0x07) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1;
}

/// An ID3 tag carrying the HLS packed-audio timestamp [pts].
List<int> id3Timestamp(int pts) {
  final owner = ascii.encode('com.apple.streaming.transportStreamTimestamp');
  final data = [...owner, 0, 0, 0, 0, (pts >> 32) & 1, (pts >> 24) & 0xFF, (pts >> 16) & 0xFF, (pts >> 8) & 0xFF, pts & 0xFF];
  final frame = [...ascii.encode('PRIV'), 0, 0, 0, data.length, 0, 0, ...data];
  return [...ascii.encode('ID3'), 4, 0, 0, 0, 0, 0, frame.length, ...frame];
}

/// A 48 kHz AC-3 frame at 192 kbps: 768 bytes, 1536 samples (32 ms).
List<int> ac3Frame() {
  final f = List<int>.filled(768, 0x55);
  f
    ..[0] = 0x0B
    ..[1] = 0x77
    ..[4] = 0x14 // fscod 0 (48 kHz), frmsizecod 20 (192 kbps)
    ..[5] = 0x40; // bsid 8
  return f;
}

// ---- ISO BMFF building and reading for the fMP4 join tests ----

Uint8List box(String type, List<int> payload) {
  final n = 8 + payload.length;
  return Uint8List.fromList([n >> 24, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF, ...ascii.encode(type), ...payload]);
}

Uint8List fullBox(String type, List<int> payload) => box(type, [0, 0, 0, 0, ...payload]);

List<int> u32(int v) => [v >> 24, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

/// An init segment with one track: [handler] `vide` or `soun`.
Uint8List mp4Init(String handler, int trackId) {
  final tkhd = fullBox('tkhd', [...u32(0), ...u32(0), ...u32(trackId), ...List.filled(68, 0)]);
  final hdlr = fullBox('hdlr', [...u32(0), ...ascii.encode(handler), ...List.filled(13, 0)]);
  final mvhd = fullBox('mvhd', [...List.filled(92, 0), ...u32(trackId + 1)]);
  final trex = fullBox('trex', [...u32(trackId), ...u32(1), ...u32(0), ...u32(0), ...u32(0)]);
  return Uint8List.fromList([
    ...box('ftyp', ascii.encode('iso6\x00\x00\x00\x00iso6')),
    ...box('moov', [...mvhd, ...box('trak', [...tkhd, ...box('mdia', hdlr)]), ...box('mvex', trex)]),
  ]);
}

/// A fragment of [trackId] whose mdat holds [marker].
Uint8List mp4Fragment(int trackId, int marker) => Uint8List.fromList([
      ...box('styp', ascii.encode('msdh\x00\x00\x00\x00msdh')),
      ...box('moof', box('traf', fullBox('tfhd', u32(trackId)))),
      ...box('mdat', [marker]),
      ...box('mfra', []),
    ]);

/// The top-level boxes of [b] as (type, start, end).
List<(String, int, int)> topBoxes(Uint8List b) {
  final out = <(String, int, int)>[];
  for (var p = 0; p + 8 <= b.length;) {
    final size = b[p] << 24 | b[p + 1] << 16 | b[p + 2] << 8 | b[p + 3];
    out.add((ascii.decode(b.sublist(p + 4, p + 8)), p, p + size));
    p += size;
  }
  return out;
}

/// Every (track ID, handler) in an init segment, and every tfhd track ID
/// and mdat marker after it, in file order.
({List<(int, String)> tracks, List<int> trex, List<(int, int)> fragments}) readMp4(Uint8List b) {
  final tracks = <(int, String)>[];
  final trex = <int>[];
  final fragments = <(int, int)>[];
  int? fragmentTrack;
  int find(String type, int from, int to) {
    final at = String.fromCharCodes(b.sublist(from, to)).indexOf(type);
    return at < 0 ? -1 : from + at;
  }
  for (final (type, start, end) in topBoxes(b)) {
    if (type == 'moov') {
      for (var t = find('tkhd', start, end); t >= 0; t = find('tkhd', t + 4, end)) {
        final h = find('hdlr', t, end);
        tracks.add((b[t + 19] | b[t + 18] << 8, ascii.decode(b.sublist(h + 12, h + 16))));
      }
      for (var t = find('trex', start, end); t >= 0; t = find('trex', t + 4, end)) {
        trex.add(b[t + 11]);
      }
    } else if (type == 'moof') {
      final t = find('tfhd', start, end);
      fragmentTrack = b[t + 11];
    } else if (type == 'mdat') {
      fragments.add((fragmentTrack!, b[start + 8]));
    }
  }
  return (tracks: tracks, trex: trex, fragments: fragments);
}

const config = CaptureConfig(
  userAgent: 'ZipTop-Test/1.0',
  referer: 'https://ref.example/',
  variantPreference: VariantPreference.highest,
  minFreeBytes: 1024,
);

void main() {
  group('M3u8Parser', () {
    test('master playlist: variants, quoted commas and relative URIs', () {
      const text = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
# a comment between the tag and its URI

https://cdn.example/high/index.m3u8
''';
      expect(M3u8Parser.isPlaylist(text), isTrue);
      expect(M3u8Parser.isMaster(text), isTrue);
      final variants = M3u8Parser.parseMaster(text, 'https://h.example/a/b/master.m3u8?t=1');
      expect(variants, hasLength(2));
      expect(variants[0].uri, 'https://h.example/a/b/low/index.m3u8');
      expect(variants[0].bandwidth, 800000);
      expect(variants[0].height, 360);
      expect(variants[1].uri, 'https://cdn.example/high/index.m3u8');
      expect(variants[1].height, 1080);
    });

    test('media playlist: sequence numbers, keys, init segment and end list', () {
      const text = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:100
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4.0,
a.m4s
#EXT-X-KEY:METHOD=AES-128,URI="/keys/k1",IV=0x000102030405060708090a0b0c0d0e0f
#EXT-X-DISCONTINUITY
#EXTINF:3.5,title
b.m4s
#EXT-X-KEY:METHOD=NONE
#EXTINF:4.0,
c.m4s
#EXT-X-ENDLIST
''';
      final playlist = M3u8Parser.parseMedia(text, 'https://h.example/live/index.m3u8');
      expect(playlist.targetDurationSec, 4);
      expect(playlist.mediaSequence, 100);
      expect(playlist.initSegmentUri, 'https://h.example/live/init.mp4');
      expect(playlist.hasEndList, isTrue);
      expect(playlist.segments.map((s) => s.sequence), [100, 101, 102]);
      expect(playlist.segments[0].key, isNull);

      final encrypted = playlist.segments[1];
      expect(encrypted.key!.isAes128, isTrue);
      expect(encrypted.key!.uri, 'https://h.example/keys/k1');
      expect(encrypted.key!.iv, List.generate(16, (i) => i));
      expect(encrypted.discontinuity, isTrue);
      expect(encrypted.durationSec, 3.5);
      expect(playlist.segments[2].key, isNull);
      expect(playlist.segments[2].discontinuity, isFalse);
    });

    test('variant choice follows the quality setting', () {
      const variants = [
        HlsVariant('low', 800000, 360),
        HlsVariant('mid', 3000000, 720),
        HlsVariant('high', 6000000, 1080),
      ];
      expect(HlsCapture.pickVariant(variants, VariantPreference.highest)!.uri, 'high');
      expect(HlsCapture.pickVariant(variants, VariantPreference.atMost720p)!.uri, 'mid');
      expect(HlsCapture.pickVariant(variants, VariantPreference.lowest)!.uri, 'low');
      // Nothing at or under 720p: take the best of what there is.
      expect(
        HlsCapture.pickVariant(const [HlsVariant('uhd', 1, 2160)], VariantPreference.atMost720p)!
            .uri,
        'uhd',
      );
      expect(HlsCapture.pickVariant(const [], VariantPreference.highest), isNull);
    });

    test('audio renditions and the variant that uses them', () {
      const text = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="English",DEFAULT=YES
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="surround",NAME="Stereo",URI="audio/2ch.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="surround",NAME="5.1",DEFAULT=YES,CHANNELS="6",URI="audio/6ch.m3u8"
#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC1",INSTREAM-ID="CC1"
#EXT-X-STREAM-INF:BANDWIDTH=6000000,AUDIO="surround",CLOSED-CAPTIONS="cc"
video/1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="stereo"
video/360.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=500000
video/240.m3u8
''';
      const base = 'https://h.example/live/master.m3u8';
      final variants = M3u8Parser.parseMaster(text, base);
      final renditions = M3u8Parser.parseRenditions(text, base);
      expect(renditions, hasLength(4));
      expect(variants[0].audioGroup, 'surround');
      // The group's default rendition, not the first one listed.
      expect(
        M3u8Parser.separateAudioUri(variants[0], renditions),
        'https://h.example/live/audio/6ch.m3u8',
      );
      // No URI: the audio is muxed into the variant.
      expect(M3u8Parser.separateAudioUri(variants[1], renditions), isNull);
      expect(M3u8Parser.separateAudioUri(variants[2], renditions), isNull);
    });

    test('the default IV is the media sequence, big-endian', () {
      final iv = HlsCapture.sequenceIv(0x0102);
      expect(iv.sublist(0, 14), List.filled(14, 0));
      expect(iv.sublist(14), [1, 2]);
    });
  });

  group('TsAudioJoiner', () {
    test('moves TS audio to its own PID and lists it in the video PMT', () {
      final joiner = TsAudioJoiner();
      final audio = readTs(joiner.audio(audioSegment(7)));
      // Only the audio packets, on the joined PID; no PSI of its own.
      expect(audio.pidPackets.keys, [TsAudioJoiner.firstAudioPid]);
      expect(audio.pidPackets[TsAudioJoiner.firstAudioPid]!.single[9], 7);

      final video = readTs(joiner.video(videoSegment(1)));
      expect(video.crcOk, isTrue);
      expect([for (final es in video.pmt) (es.type, es.pid)], [
        (0x1B, 0x100),
        (0x81, TsAudioJoiner.firstAudioPid),
      ]);
      // The audio's language descriptor goes with it.
      expect(video.pmt[1].descriptors, [0x0A, 4, 0x65, 0x6E, 0x67, 0]);
      expect(video.pidPackets[0x100]!.single[9], 1, reason: 'video untouched');
    });

    test('leaves video alone until there is audio to list', () {
      final joiner = TsAudioJoiner();
      final segment = videoSegment(1);
      expect(identical(joiner.video(segment), segment), isTrue);
      expect(joiner.hasAudio, isFalse);
    });

    test('wraps packed AC-3 in PES with the ID3 timestamp', () {
      final joiner = TsAudioJoiner();
      const start = 0x1FFFFF000; // near the 33-bit wrap
      final first = Uint8List.fromList([...id3Timestamp(start), for (var i = 0; i < 6; i++) ...ac3Frame()]);
      final out = readTs(joiner.audio(first));
      final packets = out.pidPackets[TsAudioJoiner.firstAudioPid]!;
      final starts = [for (final p in packets) if (p[1] & 0x40 != 0) p];
      // Four frames to a PES: two PES for six frames, the second 4 x 32 ms on.
      expect(starts, hasLength(2));
      expect(ptsOf(starts[0]), start);
      expect(ptsOf(starts[1]), (start + 4 * 2880) & 0x1FFFFFFFF);
      // Every byte of every frame is carried, continuity counting up.
      expect([for (final p in packets) p[3] & 0x0F], List.generate(packets.length, (i) => i & 0x0F));

      // A segment with no timestamp carries on where the last one ended.
      final second = Uint8List.fromList(ac3Frame());
      final next = readTs(joiner.audio(second)).pidPackets[TsAudioJoiner.firstAudioPid]!;
      expect(ptsOf(next.first), (start + 6 * 2880) & 0x1FFFFFFFF);

      final video = readTs(joiner.video(videoSegment(1)));
      expect(video.crcOk, isTrue);
      expect(video.pmt[1].type, 0x81);
      expect(video.pmt[1].descriptors, [0x05, 4, ...ascii.encode('AC-3')]);
    });

    test('packed audio with no timestamp to go on is dropped', () {
      expect(TsAudioJoiner().audio(Uint8List.fromList(ac3Frame())), isEmpty);
    });
  });

  group('Mp4AudioJoiner', () {
    test('merges both tracks into one init, renumbering a clashing audio ID', () {
      final (init, joiner) = Mp4AudioJoiner.join(mp4Init('vide', 1), mp4Init('soun', 1))!;
      final merged = readMp4(init);
      expect(merged.tracks, [(1, 'vide'), (2, 'soun')]);
      expect(merged.trex, [1, 2]);
      expect(topBoxes(init).map((b) => b.$1), ['ftyp', 'moov']);

      final audio = joiner.audio(mp4Fragment(1, 0xA1));
      // Only the moof/mdat pair, pointed at the new track.
      expect(topBoxes(audio).map((b) => b.$1), ['moof', 'mdat']);
      expect(readMp4(audio).fragments, [(2, 0xA1)]);
      expect(joiner.hasAudio, isTrue);
      final video = mp4Fragment(1, 0x71);
      expect(identical(joiner.video(video), video), isTrue);
    });

    test('keeps an audio track ID that does not clash', () {
      final (init, _) = Mp4AudioJoiner.join(mp4Init('vide', 1), mp4Init('soun', 7))!;
      expect(readMp4(init).tracks, [(1, 'vide'), (7, 'soun')]);
    });

    test('refuses what it cannot merge', () {
      expect(Mp4AudioJoiner.join(mp4Init('vide', 1), mp4Init('vide', 2)), isNull);
      expect(Mp4AudioJoiner.join(mp4Init('vide', 1), Uint8List(16)), isNull);
      expect(Mp4AudioJoiner.join(videoSegment(1), mp4Init('soun', 1)), isNull);
    });
  });

  group('HlsCapture against a local server', () {
    late HttpServer server;
    late String base;
    late HttpClient client;
    final requests = <String>[];
    final seenHeaders = <String, String?>{};
    late Future<void> Function(HttpRequest request) handler;

    setUp(() async {
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      client = HlsCapture.newClient();
      server.listen((request) async {
        requests.add(request.uri.path);
        seenHeaders['ua'] = request.headers.value(HttpHeaders.userAgentHeader);
        seenHeaders['referer'] = request.headers.value(HttpHeaders.refererHeader);
        await handler(request);
        await request.response.close();
      });
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });

    /// A live playlist that moves on by one segment every time it is fetched.
    String livePlaylist(int fetch, {String prefix = 'seg', String extra = ''}) => [
          '#EXTM3U',
          '#EXT-X-TARGETDURATION:1',
          '#EXT-X-MEDIA-SEQUENCE:$fetch',
          if (extra.isNotEmpty) extra,
          for (var i = fetch; i < fetch + 3; i++) ...['#EXTINF:1.0,', '$prefix$i.ts'],
          '',
        ].join('\n');

    Future<CaptureOutcome> capture(
      String path,
      MemorySink sink, {
      Duration length = const Duration(milliseconds: 2500),
      CaptureToken? token,
      Future<String?> Function()? resolveUrl,
    }) {
      final now = DateTime.now();
      return HlsCapture.run(
        initialUrl: '$base$path',
        client: client,
        sink: sink,
        config: config,
        deadline: now.add(length),
        hardCap: now.add(const Duration(hours: 1)),
        resolveUrl: resolveUrl ?? () async => null,
        onProgress: (_, _) {},
        token: token ?? CaptureToken(),
      );
    }

    test('follows a master to its best variant and appends segments in order', () async {
      var fetches = 0;
      handler = (request) async {
        final path = request.uri.path;
        if (path == '/master.m3u8') {
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=640x360\nlow/index.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=9000,RESOLUTION=1280x720\nhigh/index.m3u8\n',
          );
        } else if (path == '/high/index.m3u8') {
          request.response.write(livePlaylist(fetches++));
        } else if (path.startsWith('/high/seg')) {
          request.response.write('<${path.substring('/high/seg'.length).split('.').first}>');
        } else {
          request.response.statusCode = 404;
        }
      };

      final sink = MemorySink();
      final outcome = await capture('/master.m3u8', sink);

      expect(outcome, isA<CaptureFinished>());
      expect(outcome.container, 'ts');
      expect(outcome.gapCount, 0);
      expect(requests.any((p) => p.startsWith('/low/')), isFalse);
      expect(seenHeaders['ua'], 'ZipTop-Test/1.0');
      expect(seenHeaders['referer'], 'https://ref.example/');

      // Starts near the live edge, then every later segment exactly once.
      final numbers = RegExp(r'<(\d+)>').allMatches(sink.text).map((m) => int.parse(m[1]!)).toList();
      expect(numbers.length, greaterThanOrEqualTo(3));
      expect(numbers.first, 1);
      for (var i = 1; i < numbers.length; i++) {
        expect(numbers[i], numbers[i - 1] + 1);
      }
      expect(outcome.bytesWritten, sink.bytesWritten);
    });

    test('joins a separate audio rendition into the recording', () async {
      var videoFetches = 0;
      var audioFetches = 0;
      handler = (request) async {
        final path = request.uri.path;
        if (path == '/master.m3u8') {
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="5.1",DEFAULT=YES,URI="audio/index.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=9000,AUDIO="a"\nvideo/index.m3u8\n',
          );
        } else if (path == '/video/index.m3u8') {
          request.response.write(livePlaylist(videoFetches++));
        } else if (path == '/audio/index.m3u8') {
          request.response.write(livePlaylist(audioFetches++));
        } else if (path.startsWith('/video/seg')) {
          request.response.add(videoSegment(int.parse(path.substring(10).split('.').first)));
        } else if (path.startsWith('/audio/seg')) {
          request.response.add(audioSegment(int.parse(path.substring(10).split('.').first)));
        } else {
          request.response.statusCode = 404;
        }
      };

      final sink = MemorySink();
      final outcome = await capture('/master.m3u8', sink);

      expect(outcome, isA<CaptureFinished>());
      expect(outcome.container, 'ts');
      expect(outcome.gapCount, 0);
      final ts = readTs(sink.bytes);
      expect(ts.crcOk, isTrue);
      expect(ts.pmt.map((es) => es.pid), [0x100, TsAudioJoiner.firstAudioPid]);
      final videoNumbers = [for (final p in ts.pidPackets[0x100]!) p[9]];
      final audioNumbers = [for (final p in ts.pidPackets[TsAudioJoiner.firstAudioPid]!) p[9]];
      expect(videoNumbers.length, greaterThanOrEqualTo(3));
      // The same stretch of the stream, every segment once.
      expect(audioNumbers, videoNumbers);
      // Audio before the first video, so the first PMT already lists it.
      expect((sink.bytes[1] & 0x1F) << 8 | sink.bytes[2], TsAudioJoiner.firstAudioPid);
      expect(ts.pidPackets[0]!.length, videoNumbers.length, reason: 'only the video PSI is kept');
    });

    /// A master whose variant's audio is its own rendition, both fMP4.
    Future<void> Function(HttpRequest) fmp4Stream({required bool audioIsTs}) {
      var videoFetches = 0;
      var audioFetches = 0;
      return (request) async {
        final path = request.uri.path;
        if (path == '/master.m3u8') {
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="5.1",DEFAULT=YES,URI="audio/index.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=9000,AUDIO="a"\nvideo/index.m3u8\n',
          );
        } else if (path == '/video/index.m3u8') {
          request.response.write(livePlaylist(videoFetches++, extra: '#EXT-X-MAP:URI="init.mp4"'));
        } else if (path == '/audio/index.m3u8') {
          request.response.write(
            livePlaylist(audioFetches++, extra: audioIsTs ? '' : '#EXT-X-MAP:URI="init.mp4"'),
          );
        } else if (path == '/video/init.mp4') {
          request.response.add(mp4Init('vide', 1));
        } else if (path == '/audio/init.mp4') {
          request.response.add(mp4Init('soun', 1));
        } else if (path.startsWith('/video/seg')) {
          request.response.add(mp4Fragment(1, int.parse(path.substring(10).split('.').first)));
        } else if (path.startsWith('/audio/seg')) {
          final n = int.parse(path.substring(10).split('.').first);
          request.response.add(audioIsTs ? audioSegment(n) : mp4Fragment(1, 0x80 | n));
        } else {
          request.response.statusCode = 404;
        }
      };
    }

    test('joins a separate fMP4 audio rendition into an fMP4 recording', () async {
      handler = fmp4Stream(audioIsTs: false);
      final sink = MemorySink();
      final outcome = await capture('/master.m3u8', sink);

      expect(outcome, isA<CaptureFinished>());
      expect(outcome.container, 'mp4');
      expect(outcome.gapCount, 0);
      final mp4 = readMp4(sink.bytes);
      expect(mp4.tracks, [(1, 'vide'), (2, 'soun')]);
      final video = [for (final (track, n) in mp4.fragments) if (track == 1) n];
      final audio = [for (final (track, n) in mp4.fragments) if (track == 2) n & 0x7F];
      expect(video.length, greaterThanOrEqualTo(3));
      expect(audio, video, reason: 'the same stretch, every segment once');
      expect(mp4.fragments.every((f) => f.$1 == 1 ? f.$2 < 0x80 : f.$2 >= 0x80), isTrue);
    });

    test('mixed TS audio and fMP4 video records the video alone', () async {
      handler = fmp4Stream(audioIsTs: true);
      final sink = MemorySink();
      final outcome = await capture('/master.m3u8', sink, length: const Duration(milliseconds: 1500));

      expect(outcome, isA<CaptureFinished>());
      expect(outcome.container, 'mp4');
      final mp4 = readMp4(sink.bytes);
      expect(mp4.tracks, [(1, 'vide')]);
      expect(mp4.fragments, isNotEmpty);
      expect(requests.any((p) => p.startsWith('/audio/seg')), isFalse);
    });

    test('a stopped fMP4 capture still says it wrote mp4', () async {
      handler = fmp4Stream(audioIsTs: false);
      final token = CaptureToken();
      Timer(const Duration(milliseconds: 600), token.cancel);
      await expectLater(
        capture('/master.m3u8', MemorySink(), length: const Duration(seconds: 30), token: token),
        throwsA(isA<CaptureCancelled>().having((e) => e.container, 'container', 'mp4')),
      );
    });

    test('a fresh master URL is followed to its variant again', () async {
      var fetches = 0;
      var resolved = 0;
      handler = (request) async {
        final path = request.uri.path;
        if (path == '/new/master.m3u8') {
          request.response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=9000\nindex.m3u8\n');
        } else if (path.endsWith('index.m3u8')) {
          request.response.write(livePlaylist(fetches++));
        } else if (path.startsWith('/old/')) {
          request.response.statusCode = 403;
        } else {
          request.response.write('<${path.substring('/new/seg'.length).split('.').first}>');
        }
      };

      final sink = MemorySink();
      final outcome = await capture(
        '/old/index.m3u8',
        sink,
        length: const Duration(milliseconds: 3500),
        resolveUrl: () async {
          resolved++;
          return '$base/new/master.m3u8';
        },
      );

      expect(resolved, 1);
      expect(outcome, isA<CaptureFinished>());
      // Segments, never the variant playlist itself, reach the file.
      expect(sink.text, isNot(contains('#EXT')));
      expect(sink.text, contains('<'));
    });

    test('a missing segment is a gap, not the end of the recording', () async {
      var fetches = 0;
      handler = (request) async {
        final path = request.uri.path;
        if (path == '/index.m3u8') {
          request.response.write(livePlaylist(fetches++));
        } else if (path == '/seg3.ts') {
          request.response.statusCode = 404;
        } else {
          request.response.write('<${path.substring(4).split('.').first}>');
        }
      };

      final sink = MemorySink();
      final outcome = await capture('/index.m3u8', sink);

      expect(outcome, isA<CaptureFinished>());
      expect(outcome.gapCount, 1);
      // The playlist is read twice before the first segment (probe, then in
      // full), so a single-playlist stream starts at segment 2.
      expect(sink.text, startsWith('<2><4>'));
    });

    test('writes the fMP4 init segment first and reports mp4', () async {
      var fetches = 0;
      handler = (request) async {
        final path = request.uri.path;
        if (path == '/index.m3u8') {
          request.response.write(livePlaylist(fetches++, extra: '#EXT-X-MAP:URI="init.mp4"'));
        } else if (path == '/init.mp4') {
          request.response.write('[INIT]');
        } else {
          request.response.write('<${path.substring(4).split('.').first}>');
        }
      };

      final sink = MemorySink();
      final outcome = await capture('/index.m3u8', sink, length: const Duration(milliseconds: 1500));

      expect(outcome.container, 'mp4');
      expect(sink.text, startsWith('[INIT]<2>'));
      expect('[INIT]'.allMatches(sink.text), hasLength(1));
    });

    test('decrypts AES-128 segments with the playlist key and sequence IV', () async {
      final key = Uint8List.fromList(List.generate(16, (i) => i + 1));
      var fetches = 0;
      handler = (request) async {
        final path = request.uri.path;
        if (path == '/index.m3u8') {
          request.response.write(
            livePlaylist(fetches++, extra: '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"'),
          );
        } else if (path == '/key.bin') {
          request.response.add(key);
        } else {
          final n = int.parse(path.substring(4).split('.').first);
          request.response.add(
            encryptAes128(utf8.encode('<plain $n>'), key, HlsCapture.sequenceIv(n)),
          );
        }
      };

      final sink = MemorySink();
      final outcome = await capture('/index.m3u8', sink, length: const Duration(milliseconds: 1500));

      expect(outcome, isA<CaptureFinished>());
      expect(sink.text, startsWith('<plain 2><plain 3>'));
      expect(requests.where((p) => p == '/key.bin'), hasLength(1), reason: 'key is cached');
    });

    test('refuses SAMPLE-AES', () async {
      handler = (request) async {
        if (request.uri.path == '/index.m3u8') {
          request.response.write(
            livePlaylist(0, extra: '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"'),
          );
        } else {
          request.response.write('x');
        }
      };

      final outcome = await capture('/index.m3u8', MemorySink());
      expect((outcome as CaptureFailed).failure, RecordingFailure.unsupportedCrypto);
    });

    test('asks for a fresh URL when segments keep failing', () async {
      var fetches = 0;
      var resolved = 0;
      handler = (request) async {
        final path = request.uri.path;
        if (path.endsWith('index.m3u8')) {
          request.response.write(livePlaylist(fetches++));
        } else if (path.startsWith('/old/')) {
          request.response.statusCode = 403;
        } else {
          request.response.write('<${path.substring('/new/seg'.length).split('.').first}>');
        }
      };

      final sink = MemorySink();
      final outcome = await capture(
        '/old/index.m3u8',
        sink,
        length: const Duration(milliseconds: 3500),
        resolveUrl: () async {
          resolved++;
          return '$base/new/index.m3u8';
        },
      );

      expect(resolved, 1);
      expect(outcome, isA<CaptureFinished>());
      expect(outcome.gapCount, greaterThanOrEqualTo(1));
      expect(sink.text, contains('<'));
      expect(requests.any((p) => p.startsWith('/new/seg')), isTrue);
    });

    test('a body that is not a playlist is captured directly', () async {
      handler = (request) async {
        request.response.add(List.filled(4096, 0x47));
      };

      final sink = MemorySink();
      final outcome = await capture('/stream.ts', sink);

      // The body ended before the recording window did.
      expect(outcome, isA<CaptureFailed>());
      expect(sink.bytesWritten, 4096);
      expect(outcome.container, 'ts');
    });

    test('an unreachable stream fails without writing', () async {
      handler = (request) async => request.response.statusCode = 502;
      final sink = MemorySink();
      final outcome = await capture('/index.m3u8', sink);
      expect((outcome as CaptureFailed).failure, RecordingFailure.network);
      expect(sink.bytesWritten, 0);
    });

    test('cancelling stops the capture and keeps what was written', () async {
      var fetches = 0;
      handler = (request) async {
        final path = request.uri.path;
        if (path == '/index.m3u8') {
          request.response.write(livePlaylist(fetches++));
        } else {
          request.response.write('<${path.substring(4).split('.').first}>');
        }
      };

      final sink = MemorySink();
      final token = CaptureToken();
      Timer(const Duration(milliseconds: 600), token.cancel);
      await expectLater(
        capture('/index.m3u8', sink, length: const Duration(seconds: 30), token: token),
        throwsA(isA<CaptureCancelled>()),
      );
      expect(sink.text, startsWith('<2><3>'));
    });

    test('stops when storage runs low', () async {
      var fetches = 0;
      handler = (request) async {
        final path = request.uri.path;
        if (path == '/index.m3u8') {
          request.response.write(livePlaylist(fetches++));
        } else {
          request.response.write('x');
        }
      };

      final sink = MemorySink()..free = 10;
      final start = DateTime.now();
      // A clock that runs 40x fast, so the 30 s space check comes round.
      DateTime fastClock() => start.add(DateTime.now().difference(start) * 40);
      final outcome = await HlsCapture.run(
        initialUrl: '$base/index.m3u8',
        client: client,
        sink: sink,
        config: config,
        deadline: start.add(const Duration(hours: 1)),
        hardCap: start.add(const Duration(hours: 2)),
        resolveUrl: () async => null,
        onProgress: (_, _) {},
        token: CaptureToken(),
        clock: fastClock,
      );
      expect((outcome as CaptureFailed).failure, RecordingFailure.diskFull);
    });
  });
}
