import 'dart:io';

/// The tray icon for this platform: Windows wants an .ico, Linux
/// (StatusNotifierItem / AppIndicator) a PNG, and the macOS menu bar a
/// monochrome template image, which it tints to suit the menu bar.
String get trayIconAsset {
  if (Platform.isMacOS) return 'assets/tray_macos.png';
  if (Platform.isLinux) return 'assets/icon.png';
  return 'assets/app_icon.ico';
}

/// Whether [trayIconAsset] is a macOS template image.
bool get trayIconIsTemplate => Platform.isMacOS;

/// Where the tray icon lives, for messages to the viewer.
String get trayPlaceName => Platform.isMacOS ? 'menu bar' : 'notification area';

/// Whether there is somewhere to put a tray icon. Always true on Windows and
/// macOS (the menu bar).
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
