import 'package:flutter/foundation.dart';

/// How the video is decoded. mpv only: AVPlayer always uses the Mac's
/// hardware decoder.
enum HardwareDecoding {
  /// mpv's `auto-safe`: the GPU decoder when one is known to work.
  auto('auto-safe', 'Automatic'),

  /// `auto-copy-safe`: decode on the GPU, copy frames back. Slower, but
  /// avoids some drivers' rendering glitches.
  copy('auto-copy-safe', 'Automatic (copy back)'),

  /// Software decoding on the CPU.
  off('no', 'Off');

  const HardwareDecoding(this.mpvValue, this.label);

  final String mpvValue;
  final String label;

  static HardwareDecoding byName(String? name) => values.firstWhere(
        (v) => v.name == name,
        orElse: () => HardwareDecoding.auto,
      );
}

/// How the players look, sound and buffer. Saved per machine in
/// `SettingsStore`; every player applies them.
@immutable
class PlayerPreferences {
  const PlayerPreferences({
    this.hardwareDecoding = HardwareDecoding.auto,
    this.deinterlace = false,
    this.surround = false,
    this.fill = false,
    this.captionsByDefault = false,
    this.captionLanguage,
    this.audioLanguage,
    this.bufferSeconds = 30,
    this.bufferMegabytes = 32,
    this.tileBufferSeconds = 12,
    this.networkTimeoutSeconds = 15,
    this.stallReloadSeconds = 30,
    this.tileMaxBitrate = 4500000,
  });

  static const defaults = PlayerPreferences();

  // The choices the settings offer. Read-ahead stops at a minute: on a live
  // stream a longer one runs FFmpeg's DASH demuxer into the live edge (see
  // MpvPlayer's options).
  static const bufferSecondsChoices = [10, 20, 30, 45, 60];
  static const bufferMegabytesChoices = [16, 32, 64, 128, 256];
  static const tileBufferSecondsChoices = [4, 8, 12, 20];
  static const networkTimeoutChoices = [5, 10, 15, 30];
  static const stallReloadChoices = [10, 20, 30, 60];

  /// Bits per second; null is no limit.
  static const tileMaxBitrateChoices = <int?>[1500000, 3000000, 4500000, 8000000, null];

  final HardwareDecoding hardwareDecoding;

  /// Deinterlace broadcast (1080i, 480i) pictures. mpv only.
  final bool deinterlace;

  /// Pass 5.1 through when the stream has it, instead of mixing to stereo.
  /// mpv only.
  final bool surround;

  /// Crop the picture to fill the player instead of letterboxing it.
  final bool fill;

  /// Turn captions on when a stream has them.
  final bool captionsByDefault;

  /// ISO 639-1 codes (`en`), or null for no preference.
  final String? captionLanguage;
  final String? audioLanguage;

  /// How far ahead the main player reads.
  final int bufferSeconds;

  /// The most memory the main player's buffer may use.
  final int bufferMegabytes;

  /// How far ahead each multiview tile reads.
  final int tileBufferSeconds;

  /// How long a stalled network read waits before mpv gives up on it.
  final int networkTimeoutSeconds;

  /// How long a stream may sit buffering before it is reloaded.
  final int stallReloadSeconds;

  /// The bitrate small multiview tiles stay at or under; null for none.
  final int? tileMaxBitrate;

  Duration get stallReload => Duration(seconds: stallReloadSeconds);

  /// The Advanced page's settings put back to their defaults.
  PlayerPreferences withAdvancedDefaults() => copyWith(
        bufferSeconds: defaults.bufferSeconds,
        bufferMegabytes: defaults.bufferMegabytes,
        tileBufferSeconds: defaults.tileBufferSeconds,
        networkTimeoutSeconds: defaults.networkTimeoutSeconds,
        stallReloadSeconds: defaults.stallReloadSeconds,
      );

  bool get advancedAreDefault => withAdvancedDefaults() == this;

  static const Object _keep = Object();

  PlayerPreferences copyWith({
    HardwareDecoding? hardwareDecoding,
    bool? deinterlace,
    bool? surround,
    bool? fill,
    bool? captionsByDefault,
    Object? captionLanguage = _keep,
    Object? audioLanguage = _keep,
    int? bufferSeconds,
    int? bufferMegabytes,
    int? tileBufferSeconds,
    int? networkTimeoutSeconds,
    int? stallReloadSeconds,
    Object? tileMaxBitrate = _keep,
  }) =>
      PlayerPreferences(
        hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
        deinterlace: deinterlace ?? this.deinterlace,
        surround: surround ?? this.surround,
        fill: fill ?? this.fill,
        captionsByDefault: captionsByDefault ?? this.captionsByDefault,
        captionLanguage:
            identical(captionLanguage, _keep) ? this.captionLanguage : captionLanguage as String?,
        audioLanguage: identical(audioLanguage, _keep) ? this.audioLanguage : audioLanguage as String?,
        bufferSeconds: bufferSeconds ?? this.bufferSeconds,
        bufferMegabytes: bufferMegabytes ?? this.bufferMegabytes,
        tileBufferSeconds: tileBufferSeconds ?? this.tileBufferSeconds,
        networkTimeoutSeconds: networkTimeoutSeconds ?? this.networkTimeoutSeconds,
        stallReloadSeconds: stallReloadSeconds ?? this.stallReloadSeconds,
        tileMaxBitrate: identical(tileMaxBitrate, _keep) ? this.tileMaxBitrate : tileMaxBitrate as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is PlayerPreferences &&
      other.hardwareDecoding == hardwareDecoding &&
      other.deinterlace == deinterlace &&
      other.surround == surround &&
      other.fill == fill &&
      other.captionsByDefault == captionsByDefault &&
      other.captionLanguage == captionLanguage &&
      other.audioLanguage == audioLanguage &&
      other.bufferSeconds == bufferSeconds &&
      other.bufferMegabytes == bufferMegabytes &&
      other.tileBufferSeconds == tileBufferSeconds &&
      other.networkTimeoutSeconds == networkTimeoutSeconds &&
      other.stallReloadSeconds == stallReloadSeconds &&
      other.tileMaxBitrate == tileMaxBitrate;

  @override
  int get hashCode => Object.hash(
        hardwareDecoding,
        deinterlace,
        surround,
        fill,
        captionsByDefault,
        captionLanguage,
        audioLanguage,
        bufferSeconds,
        bufferMegabytes,
        tileBufferSeconds,
        networkTimeoutSeconds,
        stallReloadSeconds,
        tileMaxBitrate,
      );
}

/// Languages the settings offer, by ISO 639-1 code, with the other codes
/// and names streams label tracks with.
const trackLanguages = <String, ({String name, List<String> aliases})>{
  'en': (name: 'English', aliases: ['eng', 'english']),
  'es': (name: 'Spanish', aliases: ['spa', 'spanish', 'español', 'espanol']),
  'fr': (name: 'French', aliases: ['fra', 'fre', 'french', 'français', 'francais']),
  'de': (name: 'German', aliases: ['deu', 'ger', 'german', 'deutsch']),
  'pt': (name: 'Portuguese', aliases: ['por', 'portuguese', 'português', 'portugues']),
  'it': (name: 'Italian', aliases: ['ita', 'italian', 'italiano']),
  'nl': (name: 'Dutch', aliases: ['nld', 'dut', 'dutch', 'nederlands']),
  'pl': (name: 'Polish', aliases: ['pol', 'polish', 'polski']),
  'ru': (name: 'Russian', aliases: ['rus', 'russian']),
  'ar': (name: 'Arabic', aliases: ['ara', 'arabic']),
  'hi': (name: 'Hindi', aliases: ['hin', 'hindi']),
  'zh': (name: 'Chinese', aliases: ['zho', 'chi', 'chinese', 'mandarin']),
  'ja': (name: 'Japanese', aliases: ['jpn', 'japanese']),
  'ko': (name: 'Korean', aliases: ['kor', 'korean']),
  'vi': (name: 'Vietnamese', aliases: ['vie', 'vietnamese']),
  'tl': (name: 'Filipino', aliases: ['tgl', 'fil', 'tagalog', 'filipino']),
};

/// The ISO 639-1 code for a track's language tag (`en`, `eng`, `en-US`,
/// `English`), or null when it is not one [trackLanguages] knows.
String? normalizeLanguage(String? tag) {
  final text = tag?.trim().toLowerCase();
  if (text == null || text.isEmpty) return null;
  final primary = text.split(RegExp(r'[-_ ]')).first;
  for (final MapEntry(:key, :value) in trackLanguages.entries) {
    if (primary == key || value.aliases.contains(primary) || value.aliases.contains(text)) {
      return key;
    }
  }
  return null;
}
