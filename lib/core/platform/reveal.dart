import 'dart:io';

typedef ProcessRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Opens the system file manager with [filePath] selected.
///
/// Windows: Explorer. macOS: Finder. Linux: the freedesktop FileManager1
/// D-Bus interface (Nautilus, Dolphin, Nemo, Thunar…), falling back to
/// opening the folder with `xdg-open` when no file manager answers.
///
/// [os] is `Platform.operatingSystem`, overridable for tests.
Future<void> revealInFolder(
  String filePath, {
  ProcessRunner run = Process.run,
  String? os,
}) async {
  os ??= Platform.operatingSystem;
  try {
    if (os == 'windows') {
      await run('explorer.exe', ['/select,', filePath]);
      return;
    }
    if (os == 'macos') {
      await run('open', ['-R', filePath]);
      return;
    }
    if (os != 'linux') return;
    var shown = false;
    try {
      final result = await run('dbus-send', [
        '--session',
        // Wait for the answer so a missing file manager shows as a failure.
        '--print-reply',
        '--reply-timeout=5000',
        '--dest=org.freedesktop.FileManager1',
        '--type=method_call',
        '/org/freedesktop/FileManager1',
        'org.freedesktop.FileManager1.ShowItems',
        'array:string:${Uri.file(filePath)}',
        'string:',
      ]);
      shown = result.exitCode == 0;
    } catch (_) {}
    if (!shown) await run('xdg-open', [File(filePath).parent.path]);
  } catch (_) {
    // Nothing to open it with.
  }
}
