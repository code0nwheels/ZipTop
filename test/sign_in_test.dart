import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/core/api/api_client.dart';
import 'package:ziptop/core/api/api_config.dart';
import 'package:ziptop/core/api/auth_api.dart';
import 'package:ziptop/core/api/streams_api.dart';
import 'package:ziptop/core/auth/auth_events.dart';
import 'package:ziptop/core/auth/device_description.dart';
import 'package:ziptop/core/auth/token_store.dart';
import 'package:ziptop/core/models/catalog.dart';
import 'package:ziptop/core/models/json.dart';
import 'package:ziptop/core/models/playback.dart';
import 'package:ziptop/core/platform/browser.dart';
import 'package:ziptop/core/session/playback_session.dart';
import 'package:ziptop/features/login/login_controller.dart';

import 'api_client_test.dart' show FakeAdapter, Handler, jsonBody;
import 'fakes.dart';

const _device = DeviceDescription(name: 'DESKTOP-ABC', platform: 'windows', appVersion: '1.9.0');

/// Pairing as the server would answer it; records what was asked.
class _FakeAuthApi implements AuthApi {
  final calls = <String>[];
  final devices = <DeviceDescription?>[];
  var codes = 0;
  var activated = false;

  @override
  Future<PairingCode> generateCode({DeviceDescription? device}) async {
    codes++;
    devices.add(device);
    calls.add('generate');
    return PairingCode(code: 'CODE000$codes', expiresInSeconds: 10);
  }

  @override
  Future<CodeStatus> checkCode(String code) async {
    calls.add('check $code');
    return activated ? const CodeStatus(activated: true, token: 'device-token') : const CodeStatus(activated: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ApiConfig config;
  late MemoryTokenStore tokens;
  late AuthEvents events;

  ApiClient clientWith(FakeAdapter adapter) => ApiClient(
        config: config,
        tokens: tokens,
        events: events,
        dio: Dio()..httpClientAdapter = adapter,
      );

  setUp(() {
    config = ApiConfig(primary: 'https://a.example/', fallback: 'https://b.example/');
    tokens = MemoryTokenStore('tok');
    events = AuthEvents();
  });

  group('AuthApi', () {
    test('a code request says what this computer is', () async {
      final adapter = FakeAdapter((_) => jsonBody({'code': 'ABCD2345', 'expires_in_seconds': 900}));
      final code = await AuthApi(clientWith(adapter)).generateCode(device: _device);

      expect(code.code, 'ABCD2345');
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/auth/tv/generate-code');
      expect(request.data, {
        'client': 'ziptop',
        'name': 'DESKTOP-ABC',
        'platform': 'windows',
        'app_version': '1.9.0',
      });
    });

    test('describing the device returns a replacement token when there is one', () async {
      final adapter = FakeAdapter((_) => jsonBody({'success': true, 'token': 'new-token'}));
      expect(await AuthApi(clientWith(adapter)).describeDevice(_device), 'new-token');
      expect(adapter.requests.single.method, 'PUT');
      expect(adapter.requests.single.uri.path, '/api/auth/device');

      final unchanged = FakeAdapter((_) => jsonBody({'success': true, 'device': {}}));
      expect(await AuthApi(clientWith(unchanged)).describeDevice(_device), isNull);
    });

    test('a server without the device list is no trouble', () async {
      final adapter = FakeAdapter((_) => jsonBody({'error': 'Not found'}, 404));
      expect(await AuthApi(clientWith(adapter)).describeDevice(_device), isNull);
      expect(await tokens.read(), 'tok');
    });

    test('signing out tells the server, with this device token', () async {
      final adapter = FakeAdapter((_) => jsonBody({'success': true}));
      await AuthApi(clientWith(adapter)).logoutQuietly();

      final request = adapter.requests.single;
      expect(request.uri.path, '/api/auth/logout');
      expect(request.headers['Authorization'], 'Bearer tok');
    });

    test('signing out goes ahead when the server cannot be reached', () async {
      final adapter = FakeAdapter((_) => jsonBody({}), unreachableHosts: {'a.example', 'b.example'});
      await AuthApi(clientWith(adapter)).logoutQuietly();
      expect(adapter.requests, hasLength(2));
    });
  });

  group('not_entitled', () {
    StreamsApi api(Handler handler) => StreamsApi(clientWith(FakeAdapter(handler)));

    test('check-limit says the plan does not include the channel', () {
      final streams = api((_) => jsonBody({
            'success': false,
            'error': 'Your plan does not include this channel.',
            'not_entitled': true,
          }, 403));
      expect(
        streams.checkLimit('s-1'),
        throwsA(isA<NotEntitledException>()
            .having((e) => e.message, 'message', 'Your plan does not include this channel.')),
      );
    });

    test('the stream URL refusal in the v2 error shape counts too', () {
      final streams = api((_) => jsonBody({
            'error': {'code': 'not_entitled', 'message': 'Not in your plan'},
          }, 403));
      expect(streams.streamUrl('s-1'), throwsA(isA<NotEntitledException>()));
    });

    test('a 403 without the flag is still the stream limit', () {
      final streams = api((_) => jsonBody({'error': 'Stream limit reached'}, 403));
      expect(streams.checkLimit('s-1'), throwsA(isA<StreamLimitException>()));
    });

    test('a session refused by the plan says so instead of failing', () {
      fakeAsync((async) {
        final fake = FakeStreamsApi()..limitError = const NotEntitledException('Not in your plan');
        final session = PlaybackSession(fake);
        session.open('s-1', iptv: false);
        async.flushMicrotasks();

        expect(session.phase, SessionPhase.notEntitled);
        expect(session.message, 'Not in your plan');
        expect(fake.calls, ['limit s-1']);
      });
    });
  });

  group('LoginController', () {
    late _FakeAuthApi auth;
    late List<String> opened;
    late bool browserWorks;
    late int paired;

    LoginController controller() => LoginController(
          api: auth,
          config: config,
          tokens: tokens,
          device: _device,
          onPaired: () => paired++,
          browser: (url) async {
            opened.add(url);
            return browserWorks;
          },
        );

    setUp(() {
      auth = _FakeAuthApi();
      opened = [];
      browserWorks = true;
      paired = 0;
      tokens = MemoryTokenStore();
    });

    test('asks for a code describing this computer', () {
      fakeAsync((async) {
        final login = controller()..start();
        async.flushMicrotasks();

        expect(login.code, 'CODE0001');
        expect(login.linkUrl, 'https://a.example/link?code=CODE0001');
        expect(auth.devices.single, same(_device));
        login.dispose();
      });
    });

    test('the browser opens the approval page for the code', () {
      fakeAsync((async) {
        final login = controller()..start();
        async.flushMicrotasks();
        login.openBrowser();
        async.flushMicrotasks();

        expect(opened, ['https://a.example/link?code=CODE0001']);
        expect(login.browserOpened, isTrue);
        expect(login.error, isNull);
        login.dispose();
      });
    });

    test('says so when the browser will not open', () {
      fakeAsync((async) {
        browserWorks = false;
        final login = controller()..start();
        async.flushMicrotasks();
        login.openBrowser();
        async.flushMicrotasks();

        expect(login.browserOpened, isFalse);
        expect(login.error, contains("Couldn't open your browser"));
        expect(login.code, 'CODE0001');
        login.dispose();
      });
    });

    test('keeps the token and signs in once the code is approved', () {
      fakeAsync((async) {
        final login = controller()..start();
        async.flushMicrotasks();
        async.elapse(LoginController.pollInterval);
        expect(paired, 0);

        auth.activated = true;
        async.elapse(LoginController.pollInterval);
        expect(paired, 1);
        expect(tokens.read(), completion('device-token'));

        auth.calls.clear();
        async.elapse(LoginController.pollInterval * 3);
        expect(auth.calls, isEmpty, reason: 'polling stops once signed in');
        login.dispose();
      });
    });

    test('an expired code is replaced, and the browser offered again', () {
      fakeAsync((async) {
        final login = controller()..start();
        async.flushMicrotasks();
        login.openBrowser();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 13));
        expect(login.code, 'CODE0002');
        expect(login.browserOpened, isFalse);
        expect(login.error, isNull);
        login.dispose();
      });
    });
  });

  group('openInBrowser', () {
    late List<List<String>> runs;

    Future<ProcessResult> run(String executable, List<String> arguments) async {
      runs.add([executable, ...arguments]);
      return ProcessResult(0, 0, '', '');
    }

    setUp(() => runs = []);

    test('uses each platform\'s opener, with the URL as one argument', () async {
      const url = 'https://a.example/link?code=AB&x=1';
      expect(await openInBrowser(url, run: run, os: 'windows'), isTrue);
      expect(await openInBrowser(url, run: run, os: 'macos'), isTrue);
      expect(await openInBrowser(url, run: run, os: 'linux'), isTrue);
      expect(runs, [
        ['rundll32', 'url.dll,FileProtocolHandler', url],
        ['open', url],
        ['xdg-open', url],
      ]);
    });

    test('opens only web addresses', () async {
      for (final url in ['file:///etc/passwd', 'javascript:alert(1)', 'calc.exe', 'https://']) {
        expect(await openInBrowser(url, run: run, os: 'windows'), isFalse, reason: url);
      }
      expect(runs, isEmpty);
    });
  });

  group('account details', () {
    Json fixture(String name) =>
        asJson(jsonDecode(File('test/fixtures/v2/$name').readAsStringSync()))!;

    test('season plans are read from the catalogue', () {
      final plans = Catalog.fromJson(fixture('catalog-plan.json')).planStatus!;
      expect(plans.activePlans.single.name, 'Hockey Season');
      expect(plans.activePlans.single.endsAt, '2027-06-30T00:00:00');
      expect(plans.lastEnded?.name, 'Summer Pass');
      expect(plans.nextPlan, isNull);
      expect(Catalog.fromJson(fixture('catalog.json')).planStatus, isNull);
    });

    test('the account reads plan, email and limit, and counts days left', () {
      final account = AccountInfo.fromJson({
        'username': 'alice',
        'access_mode': 'plans',
        'plan_label': 'Hockey Season',
        'email': 'a@example.com',
        'stream_limit': 2,
        'expiration_date': '2026-11-20T00:00:00',
        'never_expires': false,
      });
      expect(account.accessMode, 'plans');
      expect(account.planLabel, 'Hockey Season');
      expect(account.email, 'a@example.com');
      expect(account.streamLimit, 2);
      expect(account.daysLeft(DateTime.parse('2026-11-13T00:00:00')), 7);
      expect(
        AccountInfo.fromJson({'username': 'root', 'never_expires': true}).daysLeft(DateTime(2026)),
        isNull,
      );
    });

    test('website pages follow the host that is serving', () {
      expect(config.webUrl('pricing'), 'https://a.example/pricing');
      config.markWorking('https://b.example/');
      expect(config.webUrl('/account'), 'https://b.example/account');
    });
  });
}
