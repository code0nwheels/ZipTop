import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ziptop/core/api/api_client.dart';
import 'package:ziptop/core/api/api_config.dart';
import 'package:ziptop/core/auth/auth_events.dart';
import 'package:ziptop/core/auth/token_store.dart';
import 'package:ziptop/core/platform/startup.dart';
import 'package:ziptop/core/stores/settings_store.dart';
import 'package:ziptop/features/update/update_service.dart';

class OneAnswer implements HttpClientAdapter {
  OneAnswer(this.status, this.body);
  int status;
  Object? body;
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    return ResponseBody.fromString(
      body == null ? 'not found' : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [body == null ? 'text/plain' : Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
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
      adapter = OneAnswer(200, {
        'version': '1.3.0',
        'download_url': '/downloads/ZipTop-Setup.exe',
        'available': true,
      });
      final config = ApiConfig(primary: 'https://a.example/', fallback: 'https://b.example/');
      service = UpdateService(
        client: ApiClient(
          config: config,
          tokens: MemoryTokenStore('tok'),
          events: AuthEvents(),
          dio: Dio()..httpClientAdapter = adapter,
        ),
        config: config,
        settings: settings,
        currentVersion: '1.2.0',
        clock: () => now,
      );
    });

    test('offers a newer version with an absolute download URL', () async {
      final update = await service.check();
      expect(adapter.paths.single, '/desktop/version');
      expect(update!.version, '1.3.0');
      expect(update.downloadUrl, 'https://a.example/downloads/ZipTop-Setup.exe');
      expect(settings.lastUpdateCheck, now);
    });

    test('nothing to offer when current, older or marked unavailable', () async {
      adapter.body = {'version': '1.2.0', 'download_url': '/x.exe', 'available': true};
      expect(await service.check(), isNull);
      adapter.body = {'version': '1.0.0', 'download_url': '/x.exe', 'available': true};
      expect(await service.check(), isNull);
      adapter.body = {'version': '9.0.0', 'download_url': '/x.exe', 'available': false};
      expect(await service.check(), isNull);
    });

    test('a server without the endpoint is an error for a manual check, silence for auto', () async {
      adapter
        ..status = 404
        ..body = null;
      await expectLater(service.check(), throwsStateError);
      expect(await service.autoCheck(), isNull);
    });

    test('automatic checks are rate limited and respect "Later"', () async {
      final first = await service.autoCheck();
      expect(first!.version, '1.3.0');

      now = now.add(const Duration(hours: 1));
      expect(await service.autoCheck(), isNull, reason: 'checked an hour ago');
      expect(adapter.paths, hasLength(1));

      service.dismiss(first);
      now = now.add(const Duration(hours: 7));
      expect(await service.autoCheck(), isNull, reason: 'the viewer said later');
      expect(adapter.paths, hasLength(2));

      adapter.body = {'version': '1.4.0', 'download_url': '/x.exe', 'available': true};
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
