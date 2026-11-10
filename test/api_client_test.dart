import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/core/api/api_client.dart';
import 'package:ziptop/core/api/api_config.dart';
import 'package:ziptop/core/api/streams_api.dart';
import 'package:ziptop/core/auth/auth_events.dart';
import 'package:ziptop/core/auth/token_store.dart';
import 'package:ziptop/core/models/playback.dart';

typedef Handler = ResponseBody Function(RequestOptions options);

ResponseBody jsonBody(Object body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler, {this.unreachableHosts = const {}});

  final Handler handler;
  final Set<String> unreachableHosts;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (unreachableHosts.contains(options.uri.host)) {
      throw DioException.connectionError(requestOptions: options, reason: 'unreachable');
    }
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late ApiConfig config;
  late MemoryTokenStore tokens;
  late AuthEvents events;

  ApiClient clientWith(FakeAdapter adapter) {
    final dio = Dio()..httpClientAdapter = adapter;
    return ApiClient(config: config, tokens: tokens, events: events, dio: dio);
  }

  setUp(() {
    config = ApiConfig(primary: 'https://a.example/', fallback: 'https://b.example/');
    tokens = MemoryTokenStore('tok');
    events = AuthEvents();
  });

  test('sends the bearer token and hits the primary host first', () async {
    final adapter = FakeAdapter((_) => jsonBody({'ready': true}));
    final res = await clientWith(adapter).get('api/x', query: {'a': 1, 'skip': null});

    expect(res.ok, isTrue);
    final request = adapter.requests.single;
    expect(request.uri.toString(), 'https://a.example/api/x?a=1');
    expect(request.headers['Authorization'], 'Bearer tok');
    expect(config.currentBaseUrl, 'https://a.example/');
  });

  test('fails over to the next host only when one cannot be reached', () async {
    final adapter = FakeAdapter(
      (_) => jsonBody({'ok': true}),
      unreachableHosts: {'a.example'},
    );
    final res = await clientWith(adapter).get('api/x');

    expect(res.ok, isTrue);
    expect(adapter.requests.map((r) => r.uri.host), ['a.example', 'b.example']);
    expect(config.currentBaseUrl, 'https://b.example/');
    expect(config.linkUrl('ABCD'), 'https://b.example/link?code=ABCD');
  });

  test('an HTTP error is returned as it is, without failover', () async {
    final adapter = FakeAdapter((_) => jsonBody({'error': 'boom'}, 500));
    final res = await clientWith(adapter).get('api/x');

    expect(res.statusCode, 500);
    expect(res.errorMessage, 'boom');
    expect(adapter.requests, hasLength(1));
  });

  test('throws when no host can be reached', () async {
    final adapter = FakeAdapter(
      (_) => jsonBody({}),
      unreachableHosts: {'a.example', 'b.example'},
    );
    expect(clientWith(adapter).get('api/x'), throwsA(isA<ApiException>()));
  });

  test('401 clears the token and raises Unauthorized', () async {
    final seen = <AuthEvent>[];
    events.stream.listen(seen.add);
    final adapter = FakeAdapter(
      (_) => jsonBody({
        'error': {'code': 'unauthorized', 'message': 'Authentication required'},
      }, 401),
    );
    final res = await clientWith(adapter).get('api/x');
    await Future<void>.delayed(Duration.zero);

    expect(res.errorCode, 'unauthorized');
    expect(res.errorMessage, 'Authentication required');
    expect(await tokens.read(), isNull);
    expect(seen.single, isA<Unauthorized>());
  });

  test('403 for an expired account raises AccountBlocked; other 403s do not', () async {
    final seen = <AuthEvent>[];
    events.stream.listen(seen.add);

    await clientWith(FakeAdapter((_) => jsonBody({'stream_limit': true}, 403))).get('api/x');
    await Future<void>.delayed(Duration.zero);
    expect(seen, isEmpty);

    await clientWith(FakeAdapter((_) => jsonBody({'account_expired': true}, 403)))
        .get('api/x');
    await Future<void>.delayed(Duration.zero);
    expect((seen.single as AccountBlocked).expired, isTrue);
    expect(await tokens.read(), 'tok');
  });

  group('StreamsApi reads playback responses like the Android client', () {
    StreamsApi api(Handler handler) => StreamsApi(clientWith(FakeAdapter(handler)));

    test('check-limit refusal', () {
      final streams = api(
        (_) => jsonBody({'allowed': false, 'stream_limit': 2, 'current_count': 2}),
      );
      expect(
        streams.checkLimit('s1'),
        throwsA(
          isA<StreamLimitException>()
              .having((e) => e.message, 'message', 'Stream limit reached (2/2)'),
        ),
      );
    });

    test('stream url', () async {
      final streams = api((o) {
        expect(o.uri.path, '/api/viewer/streams/s1/url');
        return jsonBody({'success': true, 'stream_url': 'https://cdn/x/index.m3u8'});
      });
      expect(await streams.streamUrl('s1'), 'https://cdn/x/index.m3u8');
    });

    test('empty stream url is an error', () {
      final streams = api((_) => jsonBody({'success': true, 'stream_url': ''}));
      expect(streams.streamUrl('s1'), throwsA(isA<ApiException>()));
    });

    test('heartbeat outcomes', () async {
      expect(await api((_) => jsonBody({'success': true})).heartbeat('s1'), isA<HeartbeatOk>());

      final warn = await api(
        (_) => jsonBody({'success': true, 'warn': true, 'seconds_remaining': 45}),
      ).heartbeat('s1');
      expect((warn as HeartbeatWarn).secondsRemaining, 45);

      final kicked = await api(
        (_) => jsonBody({'error': 'Time is up', 'max_watch_exceeded': true}, 403),
      ).heartbeat('s1');
      expect((kicked as HeartbeatKicked).reason, KickReason.watchTimeExceeded);
      expect(kicked.message, 'Time is up');

      expect(
        api((_) => jsonBody({'error': 'limit', 'stream_limit': true}, 403)).heartbeat('s1'),
        throwsA(isA<StreamLimitException>()),
      );

      final other = await api((_) => jsonBody({'error': 'gone'}, 403)).heartbeat('s1');
      expect((other as HeartbeatKicked).reason, KickReason.other);

      expect(
        api((_) => jsonBody({}, 502)).heartbeat('s1'),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
