import 'dart:io';

import 'package:path/path.dart' as p;

/// Launches ZipTop hidden in the notification area when the user signs in,
/// so scheduled recordings are not missed.
abstract class Autostart {
  /// The platform's implementation: the Run key on Windows, an XDG autostart
  /// entry on Linux.
  factory Autostart() => Platform.isLinux ? XdgAutostart() : StartupRegistration();

  /// The switch that tells ZipTop to start without showing its window.
  static const minimizedFlag = '--minimized';

  Future<bool> isEnabled();

  /// Returns whether the change was made.
  Future<bool> setEnabled(bool enabled);
}

/// "Start with Windows": an entry under the current user's Run key.
class StartupRegistration implements Autostart {
  StartupRegistration({String? executable, this.run = Process.run})
      : executable = executable ?? Platform.resolvedExecutable;

  static const runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const valueName = 'ZipTop';

  /// The switch that tells ZipTop to start without showing its window.
  static const minimizedFlag = Autostart.minimizedFlag;

  final String executable;
  final Future<ProcessResult> Function(String executable, List<String> arguments) run;

  String get command => '"$executable" $minimizedFlag';

  @override
  Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    try {
      final result = await run('reg', ['query', runKey, '/v', valueName]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isWindows) return false;
    try {
      final result = enabled
          ? await run(
              'reg',
              ['add', runKey, '/v', valueName, '/t', 'REG_SZ', '/d', command, '/f'],
            )
          : await run('reg', ['delete', runKey, '/v', valueName, '/f']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

/// "Start when I sign in" on Linux: a desktop entry in the XDG autostart
/// directory (`$XDG_CONFIG_HOME/autostart`, by default `~/.config/autostart`).
class XdgAutostart implements Autostart {
  XdgAutostart({String? configDir, String? executable})
      : configDir = configDir ?? _defaultConfigDir(),
        executable = executable ?? Platform.environment['APPIMAGE'] ?? Platform.resolvedExecutable;

  static const fileName = 'ziptop.desktop';

  /// `$XDG_CONFIG_HOME`, or `~/.config` when it is unset.
  final String configDir;

  /// The AppImage when running from one (its mount point changes every run),
  /// otherwise the binary itself.
  final String executable;

  File get file => File(p.join(configDir, 'autostart', fileName));

  String get contents => '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=ZipTop\n'
      'Comment=Keeps ZipTop running so scheduled recordings are not missed\n'
      'Exec="$executable" ${Autostart.minimizedFlag}\n'
      'Terminal=false\n'
      'X-GNOME-Autostart-enabled=true\n';

  static String _defaultConfigDir() {
    final env = Platform.environment;
    final xdg = env['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    return p.join(env['HOME'] ?? '.', '.config');
  }

  @override
  Future<bool> isEnabled() async {
    try {
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    try {
      final f = file;
      if (enabled) {
        await f.parent.create(recursive: true);
        await f.writeAsString(contents, flush: true);
      } else if (await f.exists()) {
        await f.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
