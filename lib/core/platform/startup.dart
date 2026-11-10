import 'dart:io';

/// "Start with Windows": an entry under the current user's Run key that
/// launches ZipTop hidden in the notification area at sign-in, so scheduled
/// recordings are not missed.
class StartupRegistration {
  StartupRegistration({String? executable, this.run = Process.run})
      : executable = executable ?? Platform.resolvedExecutable;

  static const runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const valueName = 'ZipTop';

  /// The switch that tells ZipTop to start without showing its window.
  static const minimizedFlag = '--minimized';

  final String executable;
  final Future<ProcessResult> Function(String executable, List<String> arguments) run;

  String get command => '"$executable" $minimizedFlag';

  Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    try {
      final result = await run('reg', ['query', runKey, '/v', valueName]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Returns whether the change was made.
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
