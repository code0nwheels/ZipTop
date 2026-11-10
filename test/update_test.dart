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
      );
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
    });
  });
}
