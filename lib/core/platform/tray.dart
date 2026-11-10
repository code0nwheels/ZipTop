import 'dart:io';

/// The tray icon for this platform: Windows wants an .ico, Linux
/// (StatusNotifierItem / AppIndicator) a PNG.
String get trayIconAsset => Platform.isLinux ? 'assets/icon.png' : 'assets/app_icon.ico';

/// Whether there is somewhere to put a tray icon. Always true on Windows.
///
/// On Linux the icon is a StatusNotifierItem, which only shows when the
/// desktop runs a StatusNotifierWatcher (KDE, most others; GNOME only with
/// the AppIndicator extension). Without one the icon would be invisible and
/// a hidden window unreachable.
Future<bool> hasTrayHost({
  Future<ProcessResult> Function(String executable, List<String> arguments) run = Process.run,
}) async {
  if (!Platform.isLinux) return true;
  try {
    final result = await run('dbus-send', [
      '--session',
      '--print-reply',
      '--reply-timeout=2000',
      '--dest=org.freedesktop.DBus',
      '/org/freedesktop/DBus',
      'org.freedesktop.DBus.NameHasOwner',
      'string:org.kde.StatusNotifierWatcher',
    ]);
    return result.exitCode == 0 && '${result.stdout}'.contains('boolean true');
  } catch (_) {
    return false;
  }
}
