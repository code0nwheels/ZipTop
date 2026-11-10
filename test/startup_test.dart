import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ziptop/core/platform/reveal.dart';
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

  group('LaunchAgentAutostart', () {
    late Directory home;

    setUp(() async => home = await Directory.systemTemp.createTemp('ziptop_launchagent'));
    tearDown(() async => home.delete(recursive: true));

    test('writes, reports and removes the launch agent', () async {
      final agent = LaunchAgentAutostart(
        home: home.path,
        executable: '/Applications/ZipTop.app/Contents/MacOS/ZipTop',
      );
      final file = File(
        p.join(home.path, 'Library', 'LaunchAgents', 'com.zipstreams.ziptop.plist'),
      );

      expect(await agent.isEnabled(), isFalse);

      expect(await agent.setEnabled(true), isTrue);
      expect(file.existsSync(), isTrue);
      final plist = file.readAsStringSync();
      expect(plist, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(plist, contains('<key>Label</key>\n\t<string>com.zipstreams.ziptop</string>'));
      expect(
        plist,
        contains(
          '<array>\n'
          '\t\t<string>/Applications/ZipTop.app/Contents/MacOS/ZipTop</string>\n'
          '\t\t<string>--minimized</string>\n'
          '\t</array>',
        ),
      );
      expect(plist, contains('<key>RunAtLoad</key>\n\t<true/>'));
      expect(await agent.isEnabled(), isTrue);

      expect(await agent.setEnabled(true), isTrue);
      expect(await agent.setEnabled(false), isTrue);
      expect(file.existsSync(), isFalse);
      expect(await agent.isEnabled(), isFalse);
      expect(await agent.setEnabled(false), isTrue);
    });

    test('escapes the executable path for XML', () {
      final agent = LaunchAgentAutostart(
        home: home.path,
        executable: '/Users/a&b/Apps/<Zip>Top.app/Contents/MacOS/ZipTop',
      );
      expect(
        agent.contents,
        contains('<string>/Users/a&amp;b/Apps/&lt;Zip&gt;Top.app/Contents/MacOS/ZipTop</string>'),
      );
    });
  });

  group('revealInFolder', () {
    late List<List<String>> calls;

    Future<ProcessResult> fakeRun(String executable, List<String> arguments, {int exitCode = 0}) async {
      calls.add([executable, ...arguments]);
      return ProcessResult(0, exitCode, '', '');
    }

    setUp(() => calls = []);

    test('selects the file in Finder on macOS', () async {
      await revealInFolder('/Users/viewer/Movies/ZipTop/News.ts', run: fakeRun, os: 'macos');
      expect(calls, [
        ['open', '-R', '/Users/viewer/Movies/ZipTop/News.ts'],
      ]);
    });

    test('selects the file in Explorer on Windows', () async {
      await revealInFolder(r'C:\Videos\News.ts', run: fakeRun, os: 'windows');
      expect(calls, [
        ['explorer.exe', '/select,', r'C:\Videos\News.ts'],
      ]);
    });

    test('falls back to xdg-open on Linux without a file manager', () async {
      await revealInFolder(
        '/home/viewer/Videos/ZipTop/News.ts',
        run: (exe, args) => fakeRun(exe, args, exitCode: exe == 'dbus-send' ? 1 : 0),
        os: 'linux',
      );
      expect(calls.first.first, 'dbus-send');
      expect(calls.last, ['xdg-open', '/home/viewer/Videos/ZipTop']);
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
    'freeDiskBytes reads the free space of a Linux or macOS volume',
    () {
      final free = freeDiskBytes(Directory.systemTemp.path);
      expect(free, isNotNull);
      expect(free, greaterThan(0));
      expect(freeDiskBytes('/no/such/directory/ziptop'), isNull);
    },
    skip: Platform.isLinux || Platform.isMacOS ? false : 'statvfs/statfs are Linux and macOS only',
  );
}
