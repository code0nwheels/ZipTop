import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ziptop/core/platform/startup.dart';
import 'package:ziptop/core/stores/settings_store.dart';
import 'package:ziptop/features/update/update_service.dart';

class OneAnswer implements HttpClientAdapter {
  OneAnswer(this.status, this.body);
  int status;
  Object? body;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      body == null ? '{"message":"Not Found"}' : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// What GitHub's latest-release endpoint answers, trimmed to what is read.
Map<String, Object?> release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  List<String> assets = const ['ZipTop-Setup-{v}.exe'],
}) {
  final v = tag.replaceFirst('v', '');
  return {
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'assets': [
      for (final name in assets)
        {
          'name': name.replaceAll('{v}', v),
          'browser_download_url':
              'https://github.com/code0nwheels/ZipTop/releases/download/$tag/${name.replaceAll('{v}', v)}',
        },
    ],
  };
}

void main() {
  test('version comparison', () {
    expect(isNewerVersion('1.2.0', '1.1.9'), isTrue);
    expect(isNewerVersion('1.10.0', '1.9.0'), isTrue);
    expect(isNewerVersion('2.0', '1.9.9'), isTrue);
    expect(isNewerVersion('v1.2.1', '1.2.0+5'), isTrue);
    expect(isNewerVersion('1.2.0', '1.2.0'), isFalse);
    expect(isNewerVersion('1.2', '1.2.0'), isFalse);
    expect(isNewerVersion('1.1.9', '1.2.0'), isFalse);
    expect(isNewerVersion('garbage', '1.0.0'), isFalse);
    // A test build comes before its release, and after the one before.
    expect(isNewerVersion('1.2.1', '1.2.1-dev.57'), isTrue);
    expect(isNewerVersion('1.2.0', '1.2.1-dev.57'), isFalse);
    expect(isNewerVersion('1.2.1-dev.60', '1.2.1-dev.57'), isFalse);
  });

  group('UpdateService', () {
    late OneAnswer adapter;
    late SettingsStore settings;
    late DateTime now;
    late UpdateService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await SettingsStore.load();
      now = DateTime(2026, 5, 1, 12);
      adapter = OneAnswer(200, release('v1.3.0'));
      service = UpdateService(
        settings: settings,
        currentVersion: '1.2.0',
        http: Dio()..httpClientAdapter = adapter,
        clock: () => now,
        platform: UpdatePlatform.windows,
      );
    });

    test('Windows ignores a release that only has the AppImage', () async {
      adapter.body = release('v1.3.0', assets: ['ZipTop-{v}-x86_64.AppImage']);
      expect(await service.check(), isNull);
    });

    test('offers a newer GitHub release and its installer', () async {
      final update = await service.check();
      final request = adapter.requests.single;
      expect(request.uri.toString(), UpdateService.latestReleaseUrl);
      expect(request.uri.host, 'api.github.com');
      expect(request.headers['User-Agent'], 'ZipTop/1.2.0');
      expect(update!.version, '1.3.0');
      expect(
        update.downloadUrl,
        'https://github.com/code0nwheels/ZipTop/releases/download/v1.3.0/ZipTop-Setup-1.3.0.exe',
      );
      expect(settings.lastUpdateCheck, now);
    });

    test('picks the installer out of other assets', () async {
      adapter.body = release('v1.3.0', assets: ['notes.txt', 'ZipTop-Setup-{v}.exe']);
      expect((await service.check())!.downloadUrl, endsWith('/ZipTop-Setup-1.3.0.exe'));
    });

    test('nothing to offer when current, older, a draft, a pre-release or missing its installer',
        () async {
      for (final body in [
        release('v1.2.0'),
        release('v1.0.0'),
        release('v9.0.0', draft: true),
        release('v9.0.0', prerelease: true),
        release('v9.0.0', assets: ['notes.txt']),
      ]) {
        adapter.body = body;
        expect(await service.check(), isNull, reason: jsonEncode(body));
      }
    });

    test('no releases, or a private repository, is an error for a manual check and silence for auto',
        () async {
      adapter
        ..status = 404
        ..body = null;
      await expectLater(service.check(), throwsStateError);
      expect(await service.autoCheck(), isNull);
      expect(settings.lastUpdateCheck, isNull);
    });

    test('automatic checks are rate limited and respect "Later"', () async {
      final first = await service.autoCheck();
      expect(first!.version, '1.3.0');

      now = now.add(const Duration(hours: 1));
      expect(await service.autoCheck(), isNull, reason: 'checked an hour ago');
      expect(adapter.requests, hasLength(1));

      service.dismiss(first);
      now = now.add(const Duration(hours: 7));
      expect(await service.autoCheck(), isNull, reason: 'the viewer said later');
      expect(adapter.requests, hasLength(2));

      adapter.body = release('v1.4.0');
      now = now.add(const Duration(hours: 7));
      expect((await service.autoCheck())!.version, '1.4.0');
    });

    test('remembers the update on offer after "Later" and across restarts', () async {
      expect(service.available.value, isNull);
      final update = await service.autoCheck();
      service.dismiss(update!);
      expect(service.available.value?.version, '1.3.0', reason: 'Later keeps the button');

      UpdateService restarted({required String version}) => UpdateService(
            settings: settings,
            currentVersion: version,
            http: Dio()..httpClientAdapter = adapter,
            clock: () => now,
            platform: UpdatePlatform.windows,
          );

      final again = restarted(version: '1.2.0');
      expect(again.available.value?.version, '1.3.0');
      expect(again.available.value?.downloadUrl, endsWith('/ZipTop-Setup-1.3.0.exe'));
      expect(adapter.requests, hasLength(1), reason: 'restored without asking GitHub');

      final installed = restarted(version: '1.3.0');
      expect(installed.available.value, isNull);
      expect(settings.knownUpdate, isNull);
    });

    test('install runs the installer silently, with no wizard', () async {
      final started = <List<String>>[];
      final original = UpdateService.detachedLauncher;
      UpdateService.detachedLauncher = (exe, args) async => started.add([exe, ...args]);
      addTearDown(() => UpdateService.detachedLauncher = original);

      final installer = File('${Directory.systemTemp.path}${Platform.pathSeparator}ZipTop-Setup-1.3.0.exe');
      await service.install(installer);

      expect(started, [
        [installer.path, '/VERYSILENT', '/NORESTART'],
      ]);
    });

    test('a check that finds nothing clears the update on offer', () async {
      await service.check();
      expect(service.available.value, isNotNull);
      adapter.body = release('v1.2.0');
      await service.check();
      expect(service.available.value, isNull);
      expect(settings.knownUpdate, isNull);
    });
  });

  group('UpdateService on Linux', () {
    late OneAnswer adapter;
    late SettingsStore settings;
    late Directory dir;
    late String appImage;
    late List<String> launched;
    late Future<void> Function(String) originalLauncher;

    UpdateService linux(Map<String, String> environment) => UpdateService(
          settings: settings,
          currentVersion: '1.2.0',
          http: Dio()..httpClientAdapter = adapter,
          platform: UpdatePlatform.linux,
          environment: environment,
        );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await SettingsStore.load();
      adapter = OneAnswer(
        200,
        release('v1.3.0', assets: ['ZipTop-Setup-{v}.exe', 'ZipTop-{v}-x86_64.AppImage']),
      );
      dir = await Directory.systemTemp.createTemp('ziptop_update_test');
      appImage = '${dir.path}${Platform.pathSeparator}ZipTop.AppImage';
      await File(appImage).writeAsString('old');
      launched = [];
      originalLauncher = UpdateService.launcher;
      UpdateService.launcher = (path) async => launched.add(path);
    });

    tearDown(() async {
      UpdateService.launcher = originalLauncher;
      await dir.delete(recursive: true);
    });

    test('picks the AppImage and ignores the installer', () async {
      final update = await linux({'APPIMAGE': appImage}).check();
      expect(
        update!.downloadUrl,
        'https://github.com/code0nwheels/ZipTop/releases/download/v1.3.0/ZipTop-1.3.0-x86_64.AppImage',
      );
    });

    test('nothing to offer when not run as an AppImage, or when its folder is missing', () async {
      expect(await linux({}).check(), isNull);
      expect(await linux({'APPIMAGE': ''}).check(), isNull);
      final gone = '${dir.path}${Platform.pathSeparator}gone${Platform.pathSeparator}ZipTop.AppImage';
      expect(await linux({'APPIMAGE': gone}).check(), isNull);
      expect(adapter.requests, isEmpty);
      expect(dir.listSync(), hasLength(1), reason: 'the write probe is cleaned up');
    });

    test('nothing to offer when the release has only the installer', () async {
      adapter.body = release('v1.3.0');
      expect(await linux({'APPIMAGE': appImage}).check(), isNull);
    });

    test('downloads next to the running AppImage', () async {
      final service = linux({'APPIMAGE': appImage});
      final file = await service.download((await service.check())!);
      expect(file.path, '$appImage.new');
      expect(await file.exists(), isTrue);
      expect(await File('$appImage.new.download').exists(), isFalse);
      expect(await File(appImage).readAsString(), 'old');
    });

    test('install swaps the new AppImage in and starts it', () async {
      final downloaded = File('$appImage.new');
      await downloaded.writeAsString('new');

      await linux({'APPIMAGE': appImage}).install(downloaded);

      expect(await File(appImage).readAsString(), 'new');
      expect(await downloaded.exists(), isFalse);
      expect(launched, [appImage]);
      if (!Platform.isWindows) {
        // The owner's execute bit (the rest depend on the umask).
        expect(File(appImage).statSync().mode & 0x40, 0x40);
      }
    });
  });

  group('UpdateService on macOS', () {
    late OneAnswer adapter;
    late SettingsStore settings;
    // Stands in for /Applications.
    late Directory applications;
    late String bundle;
    late List<List<String>> calls;
    late List<List<String>> started;
    late Future<void> Function(String, List<String>) originalLauncher;

    String join(String a, String b) => '$a${Platform.pathSeparator}$b';
    late String staged;
    late String old;

    /// Plays hdiutil and ditto: ditto "copies" a bundle marked `new` unless
    /// told to fail or to copy nothing.
    Future<ProcessResult> Function(String, List<String>) fakeRunner({
      bool dittoFails = false,
      bool dittoCopies = true,
    }) =>
        (exe, args) async {
          calls.add([exe, ...args]);
          if (exe == 'ditto') {
            if (dittoFails) {
              await Directory(args[1]).create();
              return ProcessResult(0, 1, '', 'ditto: No space left on device');
            }
            if (dittoCopies) {
              await Directory(args[1]).create();
              await File(join(args[1], 'version')).writeAsString('new');
            }
          }
          return ProcessResult(0, 0, '', '');
        };

    UpdateService mac({
      String? appBundle,
      Future<ProcessResult> Function(String, List<String>)? run,
    }) =>
        UpdateService(
          settings: settings,
          currentVersion: '1.2.0',
          http: Dio()..httpClientAdapter = adapter,
          platform: UpdatePlatform.macos,
          appBundle: appBundle ?? bundle,
          run: run ?? fakeRunner(),
        );

    Future<File> diskImage() async {
      final dmg = File(join(applications.path, 'ZipTop-1.3.0-macos-arm64.dmg'));
      await dmg.writeAsString('dmg');
      return dmg;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await SettingsStore.load();
      adapter = OneAnswer(
        200,
        release('v1.3.0', assets: [
          'ZipTop-Setup-{v}.exe',
          'ZipTop-{v}-x86_64.AppImage',
          'ZipTop-{v}-macos-x86_64.dmg',
          'ZipTop-{v}-macos-arm64.dmg',
        ]),
      );
      applications = await Directory.systemTemp.createTemp('ziptop_update_mac_test');
      bundle = join(applications.path, 'ZipTop.app');
      staged = join(applications.path, '.ZipTop-update.app');
      old = join(applications.path, '.ZipTop-old.app');
      await Directory(bundle).create();
      await File(join(bundle, 'version')).writeAsString('old');
      calls = [];
      started = [];
      originalLauncher = UpdateService.detachedLauncher;
      UpdateService.detachedLauncher = (exe, args) async => started.add([exe, ...args]);
    });

    tearDown(() async {
      UpdateService.detachedLauncher = originalLauncher;
      await applications.delete(recursive: true);
    });

    test('picks the Apple Silicon disk image and ignores the other builds', () async {
      final update = await mac().check();
      expect(
        update!.downloadUrl,
        'https://github.com/code0nwheels/ZipTop/releases/download/v1.3.0/ZipTop-1.3.0-macos-arm64.dmg',
      );
    });

    test('nothing to offer when the release has no disk image', () async {
      adapter.body = release('v1.3.0', assets: ['ZipTop-Setup-{v}.exe', 'ZipTop-{v}-x86_64.AppImage']);
      expect(await mac().check(), isNull);
    });

    test('nothing to offer unless installed as an app in a writable folder', () async {
      for (final path in [
        join(applications.path, 'ZipTop'),
        '/Volumes/ZipTop/ZipTop.app',
        '/private/var/folders/xy/abc/T/AppTranslocation/1234-ABCD/d/ZipTop.app',
        join(join(applications.path, 'gone'), 'ZipTop.app'),
      ]) {
        expect(await mac(appBundle: path).check(), isNull, reason: path);
      }
      expect(adapter.requests, isEmpty);
      expect(applications.listSync(), hasLength(1), reason: 'the write probe is cleaned up');
    });

    test('downloads the disk image to the temp folder', () async {
      final service = mac();
      final file = await service.download((await service.check())!);
      addTearDown(() => file.delete());
      expect(
        file.path,
        join(Directory.systemTemp.path, 'ZipTop-1.3.0-macos-arm64.dmg'),
      );
      expect(await file.exists(), isTrue);
      expect(await File('${file.path}.download').exists(), isFalse);
    });

    test('install copies the new app out of the image, swaps it in and hands over', () async {
      final dmg = await diskImage();
      // Left by an update that didn't finish.
      await Directory(staged).create();
      await File(join(staged, 'stale')).writeAsString('');
      await Directory(old).create();

      await mac().install(dmg);

      expect(calls, hasLength(3));
      final attach = calls[0];
      expect(attach.take(6), ['hdiutil', 'attach', '-nobrowse', '-readonly', '-noautoopen', '-mountpoint']);
      final mount = attach[6];
      expect(attach.sublist(7), [dmg.path]);
      expect(calls[1], ['ditto', join(mount, 'ZipTop.app'), staged]);
      expect(calls[2], ['hdiutil', 'detach', mount]);
      expect(await Directory(mount).exists(), isFalse, reason: 'the mount point is removed');
      expect(await dmg.exists(), isFalse, reason: 'the download is removed');

      expect(await File(join(bundle, 'version')).readAsString(), 'new');
      expect(await File(join(bundle, 'stale')).exists(), isFalse);
      expect(await File(join(old, 'version')).readAsString(), 'old');
      expect(await Directory(staged).exists(), isFalse);

      final script = started.single;
      expect(script.take(2), ['/bin/sh', '-c']);
      expect(script[2], contains('while kill -0 $pid'));
      expect(script[2], contains('rm -rf "\$1"'));
      expect(script[2], contains('open "\$2"'));
      expect(script[2], isNot(contains(applications.path)), reason: 'paths are arguments');
      expect(script.sublist(4), [old, bundle]);
    });

    test('install detaches the image even when the copy fails', () async {
      final dmg = await diskImage();
      await expectLater(
        mac(run: fakeRunner(dittoFails: true)).install(dmg),
        throwsA(isA<FileSystemException>()
            .having((e) => e.message, 'message', contains('No space left'))),
      );
      expect(calls.map((c) => c.first), ['hdiutil', 'ditto', 'hdiutil']);
      expect(calls[2], ['hdiutil', 'detach', calls[0][6]]);
      expect(await Directory(staged).exists(), isFalse, reason: 'the partial copy is removed');
      expect(await File(join(bundle, 'version')).readAsString(), 'old');
      expect(started, isEmpty);
    });

    test('install puts the running app back when the update cannot be moved in', () async {
      final dmg = await diskImage();
      await expectLater(
        mac(run: fakeRunner(dittoCopies: false)).install(dmg),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(join(bundle, 'version')).readAsString(), 'old');
      expect(await Directory(old).exists(), isFalse);
      expect(started, isEmpty);
    });

    test('install stops when the image cannot be mounted', () async {
      final dmg = await diskImage();
      final service = mac(run: (exe, args) async {
        calls.add([exe, ...args]);
        return ProcessResult(0, 1, '', 'hdiutil: attach failed - image not recognized');
      });
      await expectLater(service.install(dmg), throwsA(isA<FileSystemException>()));
      expect(calls, hasLength(1));
      expect(await Directory(calls.single[7]).exists(), isFalse);
      expect(await File(join(bundle, 'version')).readAsString(), 'old');
      expect(started, isEmpty);
    });
  });

  group('StartupRegistration', () {
    test('adds, queries and removes the Run entry with the minimized switch', () async {
      final calls = <List<String>>[];
      var exists = false;
      final startup = StartupRegistration(
        executable: r'C:\Apps\ZipTop\ziptop.exe',
        run: (exe, args) async {
          calls.add([exe, ...args]);
          if (args.first == 'add') exists = true;
          if (args.first == 'delete') exists = false;
          return ProcessResult(0, args.first == 'query' && !exists ? 1 : 0, '', '');
        },
      );

      expect(await startup.isEnabled(), isFalse);
      expect(await startup.setEnabled(true), isTrue);
      expect(await startup.isEnabled(), isTrue);
      expect(await startup.setEnabled(false), isTrue);
      expect(await startup.isEnabled(), isFalse);

      final add = calls.firstWhere((c) => c[1] == 'add');
      expect(add.first, 'reg');
      expect(add, contains(StartupRegistration.runKey));
      expect(add, contains(r'"C:\Apps\ZipTop\ziptop.exe" --minimized'));
      expect(calls.every((c) => c.contains('ZipTop')), isTrue);
      // The Run key exists only on Windows; elsewhere StartupRegistration
      // does nothing (XdgAutostart is tested in startup_test.dart).
    }, skip: Platform.isWindows ? false : 'The Run key is Windows-only');
  });
}
