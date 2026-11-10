import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ziptop/core/platform/startup.dart';
import 'package:ziptop/dvr/disk_space.dart';
import 'package:ziptop/dvr/dvr_service.dart';

void main() {
  group('XdgAutostart', () {
    late Directory config;

    setUp(() async => config = await Directory.systemTemp.createTemp('ziptop_autostart'));
    tearDown(() async => config.delete(recursive: true));

    test('writes, reports and removes the autostart entry', () async {
      final autostart = XdgAutostart(
        configDir: config.path,
        executable: '/home/viewer/Apps/ZipTop-x86_64.AppImage',
      );
      final file = File(p.join(config.path, 'autostart', 'ziptop.desktop'));

      expect(await autostart.isEnabled(), isFalse);

      expect(await autostart.setEnabled(true), isTrue);
      expect(file.existsSync(), isTrue);
      final lines = file.readAsLinesSync();
      expect(lines.first, '[Desktop Entry]');
      expect(lines, contains('Exec="/home/viewer/Apps/ZipTop-x86_64.AppImage" --minimized'));
      expect(lines, contains('Type=Application'));
      expect(lines, contains('Name=ZipTop'));
      expect(lines, contains('X-GNOME-Autostart-enabled=true'));
      expect(await autostart.isEnabled(), isTrue);

      // Enabling twice rewrites rather than fails.
      expect(await autostart.setEnabled(true), isTrue);

      expect(await autostart.setEnabled(false), isTrue);
      expect(file.existsSync(), isFalse);
      expect(await autostart.isEnabled(), isFalse);

      // Disabling when already off is fine.
      expect(await autostart.setEnabled(false), isTrue);
    });

    test('uses the --minimized switch main() looks for', () {
      expect(Autostart.minimizedFlag, StartupRegistration.minimizedFlag);
    });
  });

  group('xdgVideosDir', () {
    const home = '/home/viewer';

    test(r'expands $HOME', () {
      const dirs = '# This file is written by xdg-user-dirs-update\n'
          'XDG_DESKTOP_DIR="\$HOME/Desktop"\n'
          'XDG_VIDEOS_DIR="\$HOME/Filme"\n';
      expect(xdgVideosDir(dirs, home: home), '/home/viewer/Filme');
    });

    test('accepts absolute paths and trailing slashes', () {
      expect(xdgVideosDir('XDG_VIDEOS_DIR="/mnt/media/videos/"\n', home: home), '/mnt/media/videos');
    });

    test('is null when missing, disabled or relative', () {
      expect(xdgVideosDir('XDG_MUSIC_DIR="\$HOME/Music"\n', home: home), isNull);
      expect(xdgVideosDir('XDG_VIDEOS_DIR="\$HOME/"\n', home: home), isNull);
      expect(xdgVideosDir('XDG_VIDEOS_DIR="Videos"\n', home: home), isNull);
      expect(xdgVideosDir('', home: home), isNull);
    });

    test('ignores commented-out entries', () {
      expect(xdgVideosDir('# XDG_VIDEOS_DIR="\$HOME/Old"\n', home: home), isNull);
    });
  });

  test(
    'freeDiskBytes reads the free space of a Linux volume',
    () {
      final free = freeDiskBytes(Directory.systemTemp.path);
      expect(free, isNotNull);
      expect(free, greaterThan(0));
      expect(freeDiskBytes('/no/such/directory/ziptop'), isNull);
    },
    skip: Platform.isLinux ? false : 'statvfs is Linux-only',
  );
}
