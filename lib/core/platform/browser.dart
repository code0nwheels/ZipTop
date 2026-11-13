import 'dart:io';

import 'reveal.dart' show ProcessRunner;

/// Opens [url] in the default web browser. Only `http` and `https` URLs are
/// opened. Returns false when there is nothing to open it with.
///
/// Windows: the URL protocol handler (`rundll32 url.dll`), which, unlike
/// `cmd /c start`, takes the URL as one argument with no shell quoting. macOS:
/// `open`. Linux: `xdg-open`.
///
/// [os] is `Platform.operatingSystem`, overridable for tests.
Future<bool> openInBrowser(
  String url, {
  ProcessRunner run = Process.run,
  String? os,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) {
    return false;
  }
  os ??= Platform.operatingSystem;
  final (executable, arguments) = switch (os) {
    'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url]),
    'macos' => ('open', [url]),
    'linux' => ('xdg-open', [url]),
    _ => (null, const <String>[]),
  };
  if (executable == null) return false;
  try {
    final result = await run(executable, arguments);
    // rundll32 reports no meaningful exit code; it ran, so the handler has it.
    return os == 'windows' || result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
