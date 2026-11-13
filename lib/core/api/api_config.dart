/// Backend hosts and the URLs derived from them.
///
/// Mirrors the Android TV app's `ApiConfig`: candidates are always probed
/// primary-first, and [currentBaseUrl] records whichever host last answered so
/// the pairing link and the Referer header follow the host that is serving.
class ApiConfig {
  ApiConfig({String? primary, String? fallback})
      : candidates = <String>{
          _normalise(primary ?? _envPrimary),
          _normalise(fallback ?? _envFallback),
        }.toList(growable: false) {
    _current = candidates.first;
  }

  static const _envPrimary = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'https://al.zipstreams.live/',
  );
  static const _envFallback = String.fromEnvironment(
    'FALLBACK_URL',
    defaultValue: 'https://al.zipstreams.net/',
  );

  /// Sent on media requests. The Android app notes the CDN expects these.
  static const mediaUserAgent = String.fromEnvironment(
    'MEDIA_USER_AGENT',
    defaultValue: 'ZipStreams-AndroidTV/2.0',
  );

  /// Base URLs in fixed priority order, each ending in `/`.
  final List<String> candidates;

  late String _current;

  /// The host that served the most recent successful request.
  String get currentBaseUrl => _current;

  String get referer => _current;

  void markWorking(String baseUrl) {
    if (candidates.contains(baseUrl)) _current = baseUrl;
  }

  String linkUrl(String code) => '${_current}link?code=$code';

  /// A page of the ZipStreams website on the host that is serving, such as
  /// `account` or `pricing`.
  String webUrl(String path) =>
      '$_current${path.startsWith('/') ? path.substring(1) : path}';

  /// Shown under the pairing code, without scheme or trailing slash.
  String get linkDisplay {
    final uri = Uri.parse(_current);
    return '${uri.host}/link';
  }

  String resolveDownloadUrl(String downloadUrl) {
    if (downloadUrl.startsWith('http://') || downloadUrl.startsWith('https://')) {
      return downloadUrl;
    }
    final base = _current.endsWith('/')
        ? _current.substring(0, _current.length - 1)
        : _current;
    return downloadUrl.startsWith('/') ? '$base$downloadUrl' : '$base/$downloadUrl';
  }

  static String _normalise(String url) => url.endsWith('/') ? url : '$url/';
}
