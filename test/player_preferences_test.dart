import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ziptop/core/stores/settings_store.dart';
import 'package:ziptop/player/live_player.dart';
import 'package:ziptop/player/mpv_player.dart';
import 'package:ziptop/player/player_preferences.dart';

Future<SettingsStore> store([Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(values);
  return SettingsStore.load();
}

void main() {
  group('SettingsStore player preferences', () {
    test('defaults match what the players used before they were settings', () async {
      final prefs = (await store()).playerPreferences;
      expect(prefs, PlayerPreferences.defaults);
      expect(prefs.hardwareDecoding, HardwareDecoding.auto);
      expect(prefs.bufferSeconds, PlayerTuning.main.readaheadSeconds);
      expect(prefs.bufferMegabytes * 1024 * 1024, PlayerTuning.main.bufferBytes);
      expect(prefs.tileBufferSeconds, PlayerTuning.tile.readaheadSeconds);
      expect(prefs.tileMaxBitrate, 4500000);
      expect(prefs.stallReload, const Duration(seconds: 30));
    });

    test('every setting round-trips', () async {
      final settings = await store();
      const changed = PlayerPreferences(
        hardwareDecoding: HardwareDecoding.off,
        deinterlace: true,
        surround: true,
        fill: true,
        captionsByDefault: true,
        captionLanguage: 'es',
        audioLanguage: 'fr',
        bufferSeconds: 60,
        bufferMegabytes: 128,
        tileBufferSeconds: 4,
        networkTimeoutSeconds: 30,
        stallReloadSeconds: 10,
        tileMaxBitrate: null,
      );
      settings.playerPreferences = changed;
      expect(settings.playerPreferences, changed);
      // A fresh store over the same values reads them back.
      expect(SettingsStore(await SharedPreferences.getInstance()).playerPreferences, changed);
    });

    test('notifies once per real change only', () async {
      final settings = await store();
      var notified = 0;
      settings.addListener(() => notified++);
      settings.playerPreferences = PlayerPreferences.defaults;
      expect(notified, 0);
      settings.updatePlayerPreferences((p) => p.copyWith(fill: true));
      expect(notified, 1);
    });

    test('unknown or out-of-range values fall back to the defaults', () async {
      final prefs = (await store({
        'player_hardware_decoding': 'warp-speed',
        'player_buffer_seconds': 3600,
        'player_buffer_megabytes': -1,
        'player_tile_max_bitrate': 123,
        'player_caption_language': 'xx',
      }))
          .playerPreferences;
      expect(prefs.hardwareDecoding, HardwareDecoding.auto);
      expect(prefs.bufferSeconds, 30);
      expect(prefs.bufferMegabytes, 32);
      expect(prefs.tileMaxBitrate, 4500000);
      expect(prefs.captionLanguage, isNull);
    });

    test('restoring the advanced defaults leaves the other settings', () async {
      final settings = await store();
      settings.updatePlayerPreferences(
        (p) => p.copyWith(fill: true, bufferSeconds: 60, stallReloadSeconds: 10),
      );
      expect(settings.playerPreferences.advancedAreDefault, isFalse);
      settings.resetAdvancedPlayback();
      final prefs = settings.playerPreferences;
      expect(prefs.advancedAreDefault, isTrue);
      expect(prefs.bufferSeconds, 30);
      expect(prefs.fill, isTrue);
    });
  });

  group('copyWith', () {
    test('can clear the nullable settings', () {
      const prefs = PlayerPreferences(audioLanguage: 'en', tileMaxBitrate: 3000000);
      expect(prefs.copyWith(fill: true).audioLanguage, 'en');
      expect(prefs.copyWith(audioLanguage: null).audioLanguage, isNull);
      expect(prefs.copyWith(tileMaxBitrate: null).tileMaxBitrate, isNull);
    });
  });

  group('mpv options', () {
    test('the defaults are the options mpv had before', () {
      expect(mpvOptions(PlayerPreferences.defaults, tile: false), {
        'network-timeout': '15',
        'audio-channels': 'stereo',
        'hwdec': 'auto-safe',
        'deinterlace': 'no',
        'demuxer-max-bytes': '${32 * 1024 * 1024}',
        'demuxer-readahead-secs': '30',
        'cache-secs': '30',
      });
    });

    test('follow the settings', () {
      const prefs = PlayerPreferences(
        hardwareDecoding: HardwareDecoding.copy,
        deinterlace: true,
        surround: true,
        bufferSeconds: 60,
        bufferMegabytes: 128,
        networkTimeoutSeconds: 5,
      );
      final options = mpvOptions(prefs, tile: false);
      expect(options['hwdec'], 'auto-copy-safe');
      expect(options['deinterlace'], 'yes');
      expect(options['audio-channels'], 'auto-safe');
      expect(options['network-timeout'], '5');
      expect(options['demuxer-max-bytes'], '${128 * 1024 * 1024}');
      expect(options['cache-secs'], '60');
    });

    test('tiles keep their small buffer and use the tile read-ahead', () {
      const prefs = PlayerPreferences(bufferMegabytes: 256, tileBufferSeconds: 4);
      final options = mpvOptions(prefs, tile: true);
      expect(options['demuxer-max-bytes'], '${PlayerTuning.tile.bufferBytes}');
      expect(options['demuxer-readahead-secs'], '4');
      expect(options['cache-secs'], '4');
      expect(PlayerTuning.of(prefs, tile: true).isTile, isTrue);
      expect(PlayerTuning.of(prefs, tile: false).isTile, isFalse);
    });
  });

  group('track languages', () {
    test('normalizes codes and names', () {
      expect(normalizeLanguage('en'), 'en');
      expect(normalizeLanguage('ENG'), 'en');
      expect(normalizeLanguage('en-US'), 'en');
      expect(normalizeLanguage('English'), 'en');
      expect(normalizeLanguage('ger'), 'de');
      expect(normalizeLanguage('Español'), 'es');
      expect(normalizeLanguage('und'), isNull);
      expect(normalizeLanguage(null), isNull);
    });

    const tracks = [
      MediaTrack(id: '1', language: 'eng'),
      MediaTrack(id: '2', language: 'spa'),
      MediaTrack(id: '3', title: 'Français'),
    ];

    test('picks by language, then by title', () {
      expect(pickPreferredTrack(tracks, 'es')?.id, '2');
      expect(pickPreferredTrack(tracks, 'fr')?.id, '3');
      expect(pickPreferredTrack(tracks, 'de'), isNull);
      expect(pickPreferredTrack(tracks, null), isNull);
    });
  });

  group('TrackAutoPicker', () {
    const both = MediaTracks(
      audio: [MediaTrack(id: '1', language: 'en'), MediaTrack(id: '2', language: 'es')],
      captions: [MediaTrack.off, MediaTrack(id: '5', language: 'en'), MediaTrack(id: '6', language: 'es')],
    );

    test('picks the preferred audio and captions once per stream', () {
      final picker = TrackAutoPicker();
      const prefs = PlayerPreferences(
        audioLanguage: 'es',
        captionsByDefault: true,
        captionLanguage: 'es',
      );
      final first = picker.pick(1, both, prefs);
      expect(first.audio?.id, '2');
      expect(first.captions?.id, '6');
      // The viewer's own choices afterwards are left alone.
      final again = picker.pick(1, both, prefs);
      expect(again.audio, isNull);
      expect(again.captions, isNull);
      // A new stream picks again.
      expect(picker.pick(2, both, prefs).audio?.id, '2');
    });

    test('captions fall back to the first track, and wait for one to appear', () {
      final picker = TrackAutoPicker();
      const prefs = PlayerPreferences(captionsByDefault: true, captionLanguage: 'de');
      const noCaptions = MediaTracks(captions: [MediaTrack.off]);
      expect(picker.pick(1, noCaptions, prefs).captions, isNull);
      expect(picker.pick(1, both, prefs).captions?.id, '5');
    });

    test('leaves captions off and audio alone without preferences', () {
      final pick = TrackAutoPicker().pick(1, both, PlayerPreferences.defaults);
      expect(pick.audio, isNull);
      expect(pick.captions, isNull);
    });

    test('a muted tile gets its audio picked once it is heard', () {
      final picker = TrackAutoPicker();
      const prefs = PlayerPreferences(audioLanguage: 'es');
      expect(picker.pick(1, both, prefs, audioEnabled: false).audio, isNull);
      expect(picker.pick(1, both, prefs).audio?.id, '2');
    });
  });
}
