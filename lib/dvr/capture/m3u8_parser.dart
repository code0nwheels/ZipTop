import 'dart:typed_data';

/// A deliberately small HLS playlist parser: only the tags a live recorder
/// has to honour. Ported from the Android app's `M3u8Parser`.
class HlsVariant {
  const HlsVariant(this.uri, this.bandwidth, this.height);
  final String uri;
  final int bandwidth;
  final int? height;
}

class HlsKey {
  const HlsKey({required this.method, this.uri, this.iv});
  final String method;
  final String? uri;

  /// Explicit IV from the playlist; otherwise the media sequence is used.
  final Uint8List? iv;

  bool get isClear => method.toUpperCase() == 'NONE';
  bool get isAes128 => method.toUpperCase() == 'AES-128';
}

class HlsSegment {
  const HlsSegment({
    required this.uri,
    required this.sequence,
    required this.durationSec,
    this.key,
    this.discontinuity = false,
  });
  final String uri;
  final int sequence;
  final double durationSec;
  final HlsKey? key;
  final bool discontinuity;
}

class HlsMediaPlaylist {
  const HlsMediaPlaylist({
    required this.targetDurationSec,
    required this.mediaSequence,
    this.initSegmentUri,
    required this.segments,
    required this.hasEndList,
  });
  final double targetDurationSec;
  final int mediaSequence;
  final String? initSegmentUri;
  final List<HlsSegment> segments;
  final bool hasEndList;
}

abstract final class M3u8Parser {
  static bool isPlaylist(String text) => text.trimLeft().startsWith('#EXTM3U');

  static bool isMaster(String text) => text.contains('#EXT-X-STREAM-INF');

  static List<String> _lines(String text) => text.split(RegExp(r'\r?\n'));

  static String _afterColon(String line) {
    final index = line.indexOf(':');
    return index < 0 ? '' : line.substring(index + 1);
  }

  /// Variants of a master playlist, in playlist order, with URIs resolved
  /// against [baseUrl].
  static List<HlsVariant> parseMaster(String text, String baseUrl) {
    final variants = <HlsVariant>[];
    final lines = _lines(text);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final attrs = parseAttributes(_afterColon(line));
      final bandwidth = int.tryParse(attrs['BANDWIDTH'] ?? attrs['AVERAGE-BANDWIDTH'] ?? '') ?? 0;
      final resolution = attrs['RESOLUTION'];
      final x = resolution?.indexOf('x') ?? -1;
      final height = x < 0 ? null : int.tryParse(resolution!.substring(x + 1));
      // The URI is the next non-comment, non-blank line.
      var j = i + 1;
      while (j < lines.length &&
          (lines[j].trim().isEmpty || lines[j].trimLeft().startsWith('#'))) {
        j++;
      }
      if (j < lines.length) {
        variants.add(HlsVariant(resolve(baseUrl, lines[j].trim()), bandwidth, height));
        i = j;
      }
    }
    return variants;
  }

  static HlsMediaPlaylist parseMedia(String text, String baseUrl) {
    var targetDuration = 6.0;
    var mediaSequence = 0;
    String? initUri;
    HlsKey? currentKey;
    var pendingDuration = 0.0;
    var pendingDiscontinuity = false;
    var hasEndList = false;
    final segments = <HlsSegment>[];
    var sequence = -1;

    for (final raw in _lines(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-TARGETDURATION')) {
          targetDuration = double.tryParse(_afterColon(line).trim()) ?? targetDuration;
        } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE')) {
          mediaSequence = int.tryParse(_afterColon(line).trim()) ?? 0;
          sequence = mediaSequence;
        } else if (line.startsWith('#EXT-X-MAP')) {
          final uri = parseAttributes(_afterColon(line))['URI'];
          if (uri != null) initUri = resolve(baseUrl, uri);
        } else if (line.startsWith('#EXT-X-KEY')) {
          final attrs = parseAttributes(_afterColon(line));
          final method = attrs['METHOD'] ?? 'NONE';
          if (method.toUpperCase() == 'NONE') {
            currentKey = null;
          } else {
            final keyUri = attrs['URI'];
            final iv = attrs['IV'];
            currentKey = HlsKey(
              method: method,
              uri: keyUri == null ? null : resolve(baseUrl, keyUri),
              iv: iv == null ? null : _parseHex(iv),
            );
          }
        } else if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) {
          // Not a discontinuity marker.
        } else if (line.startsWith('#EXT-X-DISCONTINUITY')) {
          pendingDiscontinuity = true;
        } else if (line.startsWith('#EXTINF')) {
          final spec = _afterColon(line);
          final comma = spec.indexOf(',');
          pendingDuration =
              double.tryParse((comma < 0 ? spec : spec.substring(0, comma)).trim()) ?? 0.0;
        } else if (line.startsWith('#EXT-X-ENDLIST')) {
          hasEndList = true;
        }
        continue;
      }

      // A bare line is a segment URI.
      if (sequence < 0) sequence = mediaSequence;
      segments.add(
        HlsSegment(
          uri: resolve(baseUrl, line),
          sequence: sequence,
          durationSec: pendingDuration,
          key: currentKey,
          discontinuity: pendingDiscontinuity,
        ),
      );
      sequence++;
      pendingDuration = 0.0;
      pendingDiscontinuity = false;
    }

    return HlsMediaPlaylist(
      targetDurationSec: targetDuration,
      mediaSequence: mediaSequence,
      initSegmentUri: initUri,
      segments: segments,
      hasEndList: hasEndList,
    );
  }

  /// Attribute lists are comma-separated KEY=VALUE, with values optionally
  /// quoted and commas legal inside quotes (CODECS hits this).
  static Map<String, String> parseAttributes(String spec) {
    final parts = <String>[];
    final current = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < spec.length; i++) {
      final c = spec[i];
      if (c == '"') {
        inQuotes = !inQuotes;
        current.write(c);
      } else if (c == ',' && !inQuotes) {
        parts.add(current.toString());
        current.clear();
      } else {
        current.write(c);
      }
    }
    if (current.isNotEmpty) parts.add(current.toString());

    final out = <String, String>{};
    for (final part in parts) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      var value = part.substring(index + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      out[part.substring(0, index).trim()] = value;
    }
    return out;
  }

  /// Resolves a possibly-relative playlist URI against the playlist's own URL.
  static String resolve(String baseUrl, String uri) {
    final trimmed = uri.trim();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) return trimmed;
    try {
      return Uri.parse(baseUrl).resolve(trimmed).toString();
    } catch (_) {
      // A URI with characters the parser rejects: join by path prefix
      // rather than dropping the segment.
      final query = baseUrl.indexOf('?');
      final path = query < 0 ? baseUrl : baseUrl.substring(0, query);
      final slash = path.lastIndexOf('/');
      if (trimmed.startsWith('/')) {
        final root = RegExp(r'^(https?://[^/]+)').firstMatch(baseUrl)?.group(1);
        return root == null ? trimmed : '$root$trimmed';
      }
      return slash <= 0 ? trimmed : '${path.substring(0, slash)}/$trimmed';
    }
  }

  static Uint8List? _parseHex(String value) {
    var hex = value;
    if (hex.startsWith('0x') || hex.startsWith('0X')) hex = hex.substring(2);
    if (hex.length.isOdd) return null;
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }
}
