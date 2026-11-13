import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/player/playback_stats.dart';
import 'package:ziptop/ui/stats_overlay.dart';

void main() {
  group('statsFromMpv', () {
    const full = <String, String?>{
      'mpv-version': 'mpv v0.42.0-19-ga61f6c3ab',
      'video-codec': 'h264',
      'video-params/w': '1920',
      'video-params/h': '1080',
      'video-params/pixelformat': 'nv12',
      'hwdec-current': 'd3d11va',
      'container-fps': '59.940060',
      'estimated-vf-fps': '59.9',
      'video-bitrate': '5800000',
      'audio-codec-name': 'aac',
      'audio-params/samplerate': '48000',
      'audio-params/channel-count': '2',
      'demuxer-cache-duration': '12.345',
      'cache-speed': '1000000',
      'frame-drop-count': '3',
      'decoder-frame-drop-count': '0',
      'avsync': '-0.0125',
    };

    test('reads every property', () {
      final s = statsFromMpv(full, source: 'HLS', variantBitrate: 6221600);
      expect(s.engine, 'mpv v0.42.0-19-ga61f6c3ab');
      expect(s.source, 'HLS');
      expect((s.width, s.height), (1920, 1080));
      expect(s.pixelFormat, 'nv12');
      expect(s.videoCodec, 'h264');
      expect(s.decoder, 'd3d11va');
      expect(s.fps, closeTo(59.94, 0.001));
      expect(s.audioCodec, 'aac');
      expect(s.sampleRate, 48000);
      expect(s.channels, 2);
      expect(s.variantBitrate, 6221600);
      expect(s.videoBitrate, 5800000);
      expect(s.downloadRate, 8000000, reason: 'cache-speed is bytes per second');
      expect(s.bufferSeconds, closeTo(12.345, 0.0001));
      expect(s.droppedFrames, 3);
      expect(s.decoderDrops, 0);
      expect(s.avSync, closeTo(-0.0125, 0.00001));
    });

    test('missing, blank or junk properties are null', () {
      final s = statsFromMpv(const {
        'video-codec': '',
        'video-params/w': 'n/a',
        'video-params/h': null,
        'container-fps': '0',
      });
      expect(s.videoCodec, isNull);
      expect(s.width, isNull);
      expect(s.height, isNull);
      expect(s.fps, isNull);
      expect(s.engine, isNull);
      expect(statsRows(s), isEmpty);
    });

    test('falls back to the estimated frame rate', () {
      final s = statsFromMpv(const {'estimated-vf-fps': '29.97'});
      expect(s.fps, closeTo(29.97, 0.001));
    });

    test('no hardware decoder reads as software', () {
      expect(statsFromMpv(const {'hwdec-current': 'no'}).decoder, 'software');
    });
  });

  group('statsFromAvPlayer', () {
    test('reads the access log and item', () {
      final s = statsFromAvPlayer(const {
        'indicatedBitrate': 6221600.0,
        'observedBitrate': 41000000.0,
        'averageVideoBitrate': 5600000.0,
        'stalls': 1,
        'droppedFrames': 4,
        'width': 1920.0,
        'height': 1080.0,
        'bufferSeconds': 24.5,
        'fps': 30.0,
        'codec': 'avc1',
      });
      expect(s.engine, 'AVPlayer');
      expect(s.source, 'HLS');
      expect((s.width, s.height), (1920, 1080));
      expect(s.videoCodec, 'avc1');
      expect(s.variantBitrate, 6221600);
      expect(s.downloadRate, 41000000);
      expect(s.videoBitrate, 5600000);
      expect(s.stalls, 1);
      expect(s.droppedFrames, 4);
      expect(s.bufferSeconds, 24.5);
      expect(s.fps, 30);
    });

    test("AVFoundation's negative unknowns are dropped", () {
      final s = statsFromAvPlayer(const {
        'indicatedBitrate': -1.0,
        'observedBitrate': -1.0,
        'averageVideoBitrate': -1.0,
        'droppedFrames': -1,
        'stalls': -1,
      });
      expect(s.variantBitrate, isNull);
      expect(s.downloadRate, isNull);
      expect(s.videoBitrate, isNull);
      expect(s.droppedFrames, isNull);
      expect(s.stalls, isNull);
    });

    test('an empty reply is just the engine', () {
      final rows = statsRows(statsFromAvPlayer(const {}));
      expect(rows, const [('Engine', 'AVPlayer'), ('Source', 'HLS')]);
    });
  });

  group('statsRows', () {
    const stats = PlaybackStats(
      engine: 'mpv v0.42.0',
      source: 'DASH',
      width: 1280,
      height: 720,
      fps: 59.940059,
      videoCodec: 'h264',
      pixelFormat: 'yuv420p',
      decoder: 'software',
      audioCodec: 'aac',
      sampleRate: 44100,
      channels: 2,
      variantBitrate: 2149280,
      videoBitrate: 836280,
      downloadRate: 12000000,
      bufferSeconds: 7.26,
      droppedFrames: 3,
      decoderDrops: 1,
      avSync: 0.012,
    );

    test('formats each row', () {
      final rows = Map.fromEntries([
        for (final (label, value) in statsRows(stats, viewport: const Size(1280.4, 719.6)))
          MapEntry(label, value),
      ]);
      expect(rows, {
        'Engine': 'mpv v0.42.0',
        'Source': 'DASH',
        'Resolution': '1280×720 @ 59.94 fps',
        'Viewport': '1280×720',
        'Video': 'h264  ·  yuv420p  ·  software',
        'Audio': 'aac  ·  44.1 kHz  ·  2 ch',
        'Variant': '2.1 Mbps',
        'Video bitrate': '836 kbps',
        'Connection': '12.0 Mbps',
        'Buffer': '7.3 s',
        'Dropped': '3 (decoder 1)',
        'A/V sync': '+0.012 s',
      });
    });

    test('negative A/V sync and whole frame rates', () {
      final rows = statsRows(const PlaybackStats(width: 1920, height: 1080, fps: 30, avSync: -0.5));
      expect(rows, contains(('Resolution', '1920×1080 @ 30 fps')));
      expect(rows, contains(('A/V sync', '−0.500 s')));
    });

    test('never shows a URL', () {
      for (final (_, value) in statsRows(stats)) {
        expect(value, isNot(contains('http')));
      }
    });
  });

  group('StatsOverlay', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(body: SizedBox(width: 800, height: 600, child: child)),
        );

    testWidgets('polls the player and shows its rows', (tester) async {
      var reads = 0;
      await tester.pumpWidget(host(StatsOverlay(
        read: () async {
          reads++;
          return const PlaybackStats(engine: 'mpv v0.42.0', bufferSeconds: 4);
        },
        onClose: () {},
      )));
      await tester.pump();
      expect(find.text('Stats for nerds'), findsOneWidget);
      expect(find.text('mpv v0.42.0'), findsOneWidget);
      expect(reads, 1);
      await tester.pump(StatsOverlay.pollEvery);
      expect(reads, 2);
    });

    testWidgets('close and copy', (tester) async {
      var closed = false;
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(host(StatsOverlay(
        read: () async => const PlaybackStats(engine: 'AVPlayer', source: 'HLS'),
        onClose: () => closed = true,
      )));
      await tester.pump();

      await tester.tap(find.byTooltip('Copy stats'));
      await tester.pump();
      expect(copied, ['Engine: AVPlayer\nSource: HLS\nViewport: 800×600']);

      await tester.tap(find.byTooltip('Close stats (S)'));
      expect(closed, isTrue);
    });

    testWidgets('stops polling once removed', (tester) async {
      var reads = 0;
      await tester.pumpWidget(host(StatsOverlay(
        read: () async {
          reads++;
          return PlaybackStats.empty;
        },
        onClose: () {},
        compact: true,
      )));
      await tester.pump();
      await tester.pumpWidget(host(const SizedBox()));
      final before = reads;
      await tester.pump(const Duration(seconds: 3));
      expect(reads, before);
    });

    testWidgets('a read that is still running is not repeated', (tester) async {
      var reads = 0;
      final pending = Completer<PlaybackStats>();
      await tester.pumpWidget(host(StatsOverlay(
        read: () {
          reads++;
          return pending.future;
        },
        onClose: () {},
      )));
      await tester.pump(const Duration(seconds: 3));
      expect(reads, 1);
      pending.complete(PlaybackStats.empty);
      await tester.pump();
    });
  });
}
