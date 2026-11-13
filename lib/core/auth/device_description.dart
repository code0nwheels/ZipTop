import 'dart:io';

/// What ZipTop tells the server about this computer when it signs in, so the
/// web page approving it can ask "Sign in ZipTop on DESKTOP-ABC?" and the
/// account page can list it among the signed-in devices.
class DeviceDescription {
  const DeviceDescription({
    required this.name,
    required this.platform,
    required this.appVersion,
  });

  /// This computer: its host name, its OS, and this build's version.
  factory DeviceDescription.current(String appVersion) {
    String name;
    try {
      name = Platform.localHostname;
    } catch (_) {
      name = '';
    }
    return DeviceDescription(
      name: name.trim().isEmpty ? 'ZipTop' : name.trim(),
      platform: Platform.operatingSystem,
      appVersion: appVersion,
    );
  }

  static const client = 'ziptop';

  final String name;

  /// `windows`, `macos` or `linux`.
  final String platform;
  final String appVersion;

  Map<String, String> toJson() => {
        'client': client,
        'name': name,
        'platform': platform,
        'app_version': appVersion,
      };
}
