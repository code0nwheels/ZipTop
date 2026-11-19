import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/dvr/capture/m3u8_parser.dart';
import 'package:ziptop/player/mpv_player.dart';

void main() {
  group('HLS master playlist ladder', () {
    const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=836280,RESOLUTION=848x480
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6221600,RESOLUTION=1920x1080
hi/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2149280,RESOLUTION=1280x720
mid/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2149280,RESOLUTION=1280x720
mid-backup/index.m3u8
''';

    test('lists each bitrate once, highest first', () {
      final variants = variantsFromMasterPlaylist(master, 'https://cdn/x/master.m3u8');
      expect(variants, const [
        StreamVariant(bitrate: 6221600, height: 1080),
        StreamVariant(bitrate: 2149280, height: 720),
        StreamVariant(bitrate: 836280, height: 480),
      ]);
    });

    test('a media playlist has nothing to pick', () {
      const media = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg1.ts\n';
      expect(variantsFromMasterPlaylist(media, 'https://cdn/x/index.m3u8'), isEmpty);
    });
  });

  group('picking a variant like hls-bitrate', () {
    const rates = [836280, 6221600, 2149280, 2149280];

    test('no cap is the best', () => expect(pickVariant(rates, null), 1));
    test('a cap takes the best under it, first on a tie', () {
      expect(pickVariant(rates, 3000000), 2);
    });
    test('a cap under everything takes the lowest', () => expect(pickVariant(rates, 100), 0));
    test('nothing to pick', () => expect(pickVariant(const [], null), isNull));
  });

  group('trimming a master playlist to one variant', () {
    const base = 'https://cdn.example/api/hls/abc/tok/ch1/safari/index.m3u8';
    const master = '''
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",LANGUAGE="en",NAME="English",DEFAULT=YES,URI="audio/en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud2",LANGUAGE="en",NAME="English AC-3",URI="audio/ac3.m3u8"
#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc1",NAME="CC1",INSTREAM-ID="CC1"

#EXT-X-STREAM-INF:BANDWIDTH=836280,RESOLUTION=848x480,AUDIO="aud1",CLOSED-CAPTIONS="cc1"
variant/low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6221600,RESOLUTION=1920x1080,AUDIO="aud1",CLOSED-CAPTIONS="cc1"
variant/hi.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6400000,RESOLUTION=1920x1080,AUDIO="aud2",CLOSED-CAPTIONS="cc1"
variant/hi-ac3.m3u8
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="variant/iframes.m3u8"
''';

    test('keeps the chosen variant and only the renditions it uses', () {
      final trimmed = trimMasterPlaylist(master, base, cap: 6300000)!;
      expect(trimmed, '''
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",LANGUAGE="en",NAME="English",DEFAULT=YES,URI="https://cdn.example/api/hls/abc/tok/ch1/safari/audio/en.m3u8"
#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc1",NAME="CC1",INSTREAM-ID="CC1"
#EXT-X-STREAM-INF:BANDWIDTH=6221600,RESOLUTION=1920x1080,AUDIO="aud1",CLOSED-CAPTIONS="cc1"
https://cdn.example/api/hls/abc/tok/ch1/safari/variant/hi.m3u8
''');
    });

    test('no cap takes the top variant and its own audio group', () {
      final trimmed = trimMasterPlaylist(master, base)!;
      expect(trimmed, contains('safari/variant/hi-ac3.m3u8'));
      expect(trimmed, contains('audio/ac3.m3u8'));
      expect(trimmed, isNot(contains('audio/en.m3u8')));
      expect(trimmed, isNot(contains('iframes')));
      expect('#EXT-X-STREAM-INF'.allMatches(trimmed).length, 1);
    });

    test('a media playlist is left alone', () {
      const media = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg1.ts\n';
      expect(trimMasterPlaylist(media, base), isNull);
    });
  });

  group('mpv track-list', () {
    // The shape libmpv 0.42 reports for a DASH manifest with several
    // video representations.
    final trackList = jsonEncode([
      {'id': 1, 'type': 'video', 'hls-bitrate': 3134488, 'demux-h': 576, 'selected': false},
      {'id': 2, 'type': 'video', 'hls-bitrate': 9914554, 'demux-h': 1080, 'selected': true},
      {'id': 3, 'type': 'video', 'hls-bitrate': 254320, 'demux-h': 180, 'selected': false},
      {'id': 4, 'type': 'video', 'albumart': true, 'image': true, 'selected': false},
      {'id': 1, 'type': 'audio', 'hls-bitrate': 67071, 'selected': true},
    ]);

    test('video representations become the ladder', () {
      expect(variantsFromTrackList(trackList), const [
        StreamVariant(bitrate: 9914554, height: 1080),
        StreamVariant(bitrate: 3134488, height: 576),
        StreamVariant(bitrate: 254320, height: 180),
      ]);
    });

    test('the selected video track gives the playing bitrate', () {
      expect(selectedVideoBitrate(trackList), 9914554);
    });

    test('junk is no tracks', () {
      expect(variantsFromTrackList(''), isEmpty);
      expect(variantsFromTrackList('{"not":"a list"}'), isEmpty);
      expect(selectedVideoBitrate(''), isNull);
    });
  });

  test('bitrate labels', () {
    expect(formatBitrate(6221600), '6.2 Mbps');
    expect(formatBitrate(836280), '836 kbps');
    expect(const StreamVariant(bitrate: 2149280, height: 720).label, '720p  ·  2.1 Mbps');
    expect(const StreamVariant(bitrate: 2149280).label, '2.1 Mbps');
  });

  group('live start index', () {
    // A live window of [count] segments, each [seconds] long.
    HlsMediaPlaylist live(int count, {double seconds = 3.003, bool ended = false}) =>
        M3u8Parser.parseMedia(
          [
            '#EXTM3U',
            '#EXT-X-TARGETDURATION:4',
            '#EXT-X-MEDIA-SEQUENCE:3479',
            for (var i = 0; i < count; i++) ...['#EXTINF:$seconds,', 'seg$i.ts'],
            if (ended) '#EXT-X-ENDLIST',
          ].join('\n'),
          'https://example.test/live/video.m3u8',
        );

    test('starts far enough back to hold the read ahead', () {
      expect(liveStartIndex(live(20), 30), -10);
      expect(liveStartIndex(live(20), 20), -7);
      expect(liveStartIndex(live(20, seconds: 6), 30), -5);
    });

    test('never starts closer to live than FFmpeg would', () {
      expect(liveStartIndex(live(20), 4), -3);
      expect(liveStartIndex(live(20, seconds: 10), 10), -3);
    });

    test('keeps clear of the oldest segments', () {
      expect(liveStartIndex(live(20), 60), -18);
      expect(liveStartIndex(live(4), 30), -3);
    });

    test('leaves a finished playlist alone', () {
      expect(liveStartIndex(live(20, ended: true), 30), isNull);
      expect(liveStartIndex(live(0), 30), isNull);
    });

    test('finds the variant in a trimmed master', () {
      const master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=6627968,AUDIO="a"
video.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=836280,AUDIO="a"
low.m3u8
''';
      final trimmed = trimMasterPlaylist(master, 'https://example.test/live/master.m3u8')!;
      expect(trimmedVariantUri(trimmed), 'https://example.test/live/video.m3u8');
    });
  });

  group('ProgressTracker', () {
    Duration s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

    test('steady playback reports healthy every two seconds', () {
      final progress = ProgressTracker();
      final healthy = [
        for (var t = 0.0; t <= 6.01; t += 0.5) progress.update(s(t)),
      ].where((h) => h).length;
      expect(healthy, 3);
    });

    test('playback after a jump back still counts', () {
      final progress = ProgressTracker();
      for (var t = 100.0; t <= 110; t += 0.5) {
        progress.update(s(t));
      }
      final mark = progress.played;
      // The stream re-reads a few seconds it already showed.
      progress.update(s(104));
      var healthy = false;
      for (var t = 104.5; t <= 107; t += 0.5) {
        healthy = progress.update(s(t)) || healthy;
      }
      expect(healthy, isTrue);
      expect(progress.movedSince(mark), isTrue);
    });

    test('a stuck position is not movement', () {
      final progress = ProgressTracker();
      progress.update(s(10));
      final mark = progress.played;
      for (var i = 0; i < 8; i++) {
        progress.update(s(10));
      }
      expect(progress.movedSince(mark), isFalse);
    });

    test('a big jump forward is not playback', () {
      final progress = ProgressTracker();
      progress.update(s(0));
      expect(progress.update(s(60)), isFalse);
      expect(progress.played, Duration.zero);
    });
  });
}
