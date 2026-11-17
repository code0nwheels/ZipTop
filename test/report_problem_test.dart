import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/core/api/api_client.dart';
import 'package:ziptop/core/api/api_config.dart';
import 'package:ziptop/core/api/streams_v2_api.dart';
import 'package:ziptop/core/auth/auth_events.dart';
import 'package:ziptop/core/auth/token_store.dart';
import 'package:ziptop/core/models/catalog.dart';
import 'package:ziptop/core/models/playback.dart';
import 'package:ziptop/features/live/report_dialog.dart';
import 'package:ziptop/theme.dart';

ResponseBody jsonBody(Object body, int status) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ResponseBody htmlBody(int status) => ResponseBody.fromString(
      '<!doctype html><title>$status</title>',
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );

Map<String, Object> v2Error(String code, String message) => {
      'error': {'code': code, 'message': message},
    };

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.respond, {this.unreachable = false});

  final ResponseBody Function(RequestOptions options) respond;
  final bool unreachable;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (unreachable) {
      throw DioException.connectionError(requestOptions: options, reason: 'unreachable');
    }
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('reportProblem request', () {
    late FakeAdapter adapter;

    StreamsV2Api api(ResponseBody Function(RequestOptions) respond, {bool unreachable = false}) {
      adapter = FakeAdapter(respond, unreachable: unreachable);
      return StreamsV2Api(
        ApiClient(
          config: ApiConfig(primary: 'https://a.example/', fallback: 'https://b.example/'),
          tokens: MemoryTokenStore('device-token'),
          events: AuthEvents(),
          dio: Dio()..httpClientAdapter = adapter,
        ),
      );
    }

    ResponseBody created(RequestOptions _) => jsonBody(
          {'report_id': 41, 'stream_id': 's-nhl-2', 'issue_type': 'wrong_channel', 'created': true},
          201,
        );

    test('posts JSON with the bearer token to the stream\'s report path', () async {
      final result = await api(created).reportProblem(
        's-nhl-2',
        const ProblemReport(IssueType.wrongChannel, note: '  Shows the news instead of the match  '),
      );

      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.toString(), 'https://a.example/api/v2/streams/s-nhl-2/report');
      expect(request.headers['Authorization'], 'Bearer device-token');
      expect(request.contentType, startsWith('application/json'));
      expect(request.data, {
        'issue_type': 'wrong_channel',
        'note': 'Shows the news instead of the match',
      });
      expect(result.reportId, 41);
      expect(result.created, isTrue);
    });

    test('ids are path-encoded', () async {
      await api(created).reportProblem('a/b c', const ProblemReport(IssueType.other));
      expect(adapter.requests.single.uri.path, '/api/v2/streams/a%2Fb%20c/report');
    });

    test('a blank note is sent as null; a long one is cut to 500 characters', () {
      expect(const ProblemReport(IssueType.down).toJson(), {'issue_type': 'down', 'note': null});
      expect(const ProblemReport(IssueType.down, note: '   ').toJson()['note'], isNull);
      final long = ProblemReport(IssueType.buffering, note: 'x' * 600).toJson();
      expect((long['note']! as String).length, ProblemReport.maxNoteLength);
    });

    test('every issue type has the wire name the server accepts', () {
      expect(
        IssueType.values.map((t) => t.wire),
        ['down', 'wrong_channel', 'buffering', 'audio_video', 'other'],
      );
    });

    test('a refreshed earlier report (200, created false) is a success', () async {
      final result = await api(
        (_) => jsonBody(
          {'report_id': 41, 'stream_id': 's-nhl-2', 'issue_type': 'down', 'created': false},
          200,
        ),
      ).reportProblem('s-nhl-2', const ProblemReport(IssueType.down));
      expect(result.created, isFalse);
    });

    Future<ApiException> failure(ResponseBody Function(RequestOptions) respond,
        {bool unreachable = false}) async {
      try {
        await api(respond, unreachable: unreachable)
            .reportProblem('s-nhl-2', const ProblemReport(IssueType.down));
      } on ApiException catch (e) {
        return e;
      }
      fail('expected an ApiException');
    }

    test('errors show the server\'s message', () async {
      final notEntitled = await failure(
        (_) => jsonBody(v2Error('not_entitled', "Your plan doesn't include this channel."), 403),
      );
      expect(notEntitled.message, "Your plan doesn't include this channel.");
      expect(notEntitled.status, 403);

      final notFound = await failure((_) => jsonBody(v2Error('not_found', 'No such stream.'), 404));
      expect(notFound.message, 'No such stream.');

      final invalid = await failure(
        (_) => jsonBody(v2Error('invalid_request', 'Choose what is wrong with the channel.'), 400),
      );
      expect(invalid.message, 'Choose what is wrong with the channel.');
    });

    test('429 says to try later', () async {
      final limited = await failure(
        (_) => jsonBody(v2Error('rate_limited', '10 per 1 hour'), 429),
      );
      expect(limited.message, StreamsV2Api.reportRateLimited);
      expect(limited.status, 429);
    });

    test('an older server without the endpoint gets the generic text', () async {
      expect((await failure((_) => htmlBody(404))).message, StreamsV2Api.reportFailed);
      expect((await failure((_) => htmlBody(405))).message, StreamsV2Api.reportFailed);
      expect(
        (await failure((_) => jsonBody(v2Error('method_not_allowed', 'Method Not Allowed'), 405)))
            .message,
        StreamsV2Api.reportFailed,
      );
      expect((await failure((_) => jsonBody({}, 500))).message, StreamsV2Api.reportFailed);
    });

    test('an unreachable server throws without a status', () async {
      final offline = await failure((_) => jsonBody({}, 200), unreachable: true);
      expect(offline.status, isNull);
    });
  });

  group('ReportProblemDialog', () {
    const channel = Channel(id: 's-nhl-2', name: 'NHL 2');
    late List<(String, ProblemReport)> sent;
    late Future<ReportResult> Function() answer;

    setUp(() {
      sent = [];
      answer = () async => const ReportResult(reportId: 1, created: true);
    });

    Future<void> open(WidgetTester tester, {IssueType? initial}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showReportProblemDialog(
                    context,
                    channel: channel,
                    initial: initial,
                    send: (id, report) {
                      sent.add((id, report));
                      return answer();
                    },
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    FilledButton sendButton(WidgetTester tester) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send'));

    testWidgets('lists the five issues; Send is disabled until one is picked', (tester) async {
      await open(tester);
      for (final issue in IssueType.values) {
        expect(find.text(issue.label), findsOneWidget);
      }
      expect(sendButton(tester).onPressed, isNull);

      await tester.tap(find.text('Buffering or stuttering'));
      await tester.pump();
      expect(sendButton(tester).onPressed, isNotNull);
    });

    testWidgets('the error state opens it with "down" picked', (tester) async {
      await open(tester, initial: IssueType.down);
      expect(sendButton(tester).onPressed, isNotNull);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(sent.single.$1, 's-nhl-2');
      expect(sent.single.$2.issueType, IssueType.down);
    });

    testWidgets('sends the note, closes and thanks the viewer', (tester) async {
      await open(tester);
      await tester.tap(find.text('Wrong channel or content'));
      await tester.enterText(find.byKey(const ValueKey('report-note')), 'Shows the news');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(sent.single.$2.toJson(), {'issue_type': 'wrong_channel', 'note': 'Shows the news'});
      expect(find.byType(ReportProblemDialog), findsNothing);
      expect(find.text("Thanks, we've let the team know."), findsOneWidget);
    });

    testWidgets('the note is capped at 500 characters as it is typed', (tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('report-note')), 'x' * 600);
      await tester.pump();
      final field = tester.widget<TextField>(find.byKey(const ValueKey('report-note')));
      expect(field.controller!.text.length, 500);
    });

    testWidgets('a failure stays open with the reason and can be sent again', (tester) async {
      answer = () async => throw const ApiException(StreamsV2Api.reportRateLimited, status: 429);
      await open(tester, initial: IssueType.down);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(find.byType(ReportProblemDialog), findsOneWidget);
      expect(find.text(StreamsV2Api.reportRateLimited), findsOneWidget);
      expect(find.text("Thanks, we've let the team know."), findsNothing);
      expect(sendButton(tester).onPressed, isNotNull);
    });

    testWidgets('an unreachable server shows the generic text', (tester) async {
      answer = () async => throw const ApiException("Can't reach ZipStreams.");
      await open(tester, initial: IssueType.down);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text(StreamsV2Api.reportFailed), findsOneWidget);
    });

    testWidgets('works from the keyboard', (tester) async {
      await open(tester);
      // The first choice has focus; Space picks it.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(sendButton(tester).onPressed, isNotNull);

      // Arrow keys move between the choices.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      // Tab past the rest of the dialog to Send.
      final send = find.widgetWithText(FilledButton, 'Send');
      for (var i = 0; i < 10 && !Focus.of(tester.element(find.text('Send'))).hasFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(send, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sent.single.$2.issueType, IssueType.wrongChannel);
    });

    testWidgets('Escape and Cancel close it without sending', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ReportProblemDialog), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportProblemDialog), findsNothing);
      expect(sent, isEmpty);
    });
  });
}
