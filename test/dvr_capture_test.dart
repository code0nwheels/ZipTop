import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:ziptop/dvr/capture/hls_capture.dart';
import 'package:ziptop/dvr/capture/m3u8_parser.dart';
import 'package:ziptop/dvr/models.dart';

class MemorySink implements CaptureSink {
  final _bytes = BytesBuilder();
  int? free;

  String get text => utf8.decode(_bytes.toBytes());

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

    test('the default IV is the media sequence, big-endian', () {
      final iv = HlsCapture.sequenceIv(0x0102);
      expect(iv.sublist(0, 14), List.filled(14, 0));
      expect(iv.sublist(14), [1, 2]);
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
