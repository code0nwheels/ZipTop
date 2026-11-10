import 'dart:io';

import 'package:path/path.dart' as p;

/// Launches ZipTop hidden in the notification area when the user signs in,
/// so scheduled recordings are not missed.
abstract class Autostart {
  /// The platform's implementation: the Run key on Windows, an XDG autostart
  /// entry on Linux, a launch agent on macOS.
  factory Autostart() {
    if (Platform.isMacOS) return LaunchAgentAutostart();
    if (Platform.isLinux) return XdgAutostart();
    return StartupRegistration();
  }

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

/// "Open at login" on macOS: a launch agent in `~/Library/LaunchAgents`,
/// which launchd runs when the viewer logs in. macOS lists it under System
/// Settings > General > Login Items as a background item.
class LaunchAgentAutostart implements Autostart {
  LaunchAgentAutostart({String? home, String? executable})
      : home = home ?? Platform.environment['HOME'] ?? '.',
        executable = executable ?? Platform.resolvedExecutable;

  /// The app's bundle identifier (PRODUCT_BUNDLE_IDENTIFIER in
  /// macos/Runner/Configs/AppInfo.xcconfig).
  static const label = 'com.zipstreams.ziptop';

  final String home;

  /// `ZipTop.app/Contents/MacOS/ZipTop`.
  final String executable;

  File get file => File(p.join(home, 'Library', 'LaunchAgents', '$label.plist'));

  static String _xml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  String get contents => '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '\t<key>Label</key>\n'
      '\t<string>$label</string>\n'
      '\t<key>ProgramArguments</key>\n'
      '\t<array>\n'
      '\t\t<string>${_xml(executable)}</string>\n'
      '\t\t<string>${Autostart.minimizedFlag}</string>\n'
      '\t</array>\n'
      '\t<key>RunAtLoad</key>\n'
      '\t<true/>\n'
      '\t<key>ProcessType</key>\n'
      '\t<string>Interactive</string>\n'
      '\t<key>LimitLoadToSessionType</key>\n'
      '\t<string>Aqua</string>\n'
      '</dict>\n'
      '</plist>\n';

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
