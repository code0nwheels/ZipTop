import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/core/platform/app_channel.dart';

/// Plays macos/Runner/AppDelegate.swift: sends `quitRequested` and returns
/// what Dart answered. The delegate quits at once unless the answer is true.
/// (This test messenger answers null for a channel with no handler; the real
/// one holds the message instead, which is why main() installs the handler.)
Future<Object?> requestQuit() async {
  const codec = StandardMethodCodec();
  final reply = await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    AppChannel.channel.name,
    codec.encodeMethodCall(const MethodCall('quitRequested')),
    (_) {},
  );
  return reply == null ? null : codec.decodeEnvelope(reply);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppChannel.enabled = true;
    AppChannel.install();
  });
  tearDown(AppChannel.stopListening);

  test('with the shell not up, a quit is answered "not taken", so macOS quits at once', () async {
    // The pairing screen: answered false, not left unanswered.
    expect(await requestQuit(), isFalse);
  });

  test('the shell takes a quit at once, before its shutdown finishes', () async {
    final shutdown = Completer<void>();
    var asked = 0;
    AppChannel.listen(onQuitRequested: () {
      asked++;
      // Waiting on "Keep ZipTop running?" or the streams closing.
      return shutdown.future;
    });

    expect(await requestQuit(), isTrue);
    expect(asked, 1);
    expect(shutdown.isCompleted, isFalse);
    shutdown.complete();
  });

  test('after the shell stops listening (signed out), quits go through again', () async {
    AppChannel.listen(onQuitRequested: () async {});
    expect(await requestQuit(), isTrue);

    AppChannel.stopListening();
    expect(await requestQuit(), isFalse);
  });

  test('a quit sent while the shell was not up is not handed to it later', () async {
    expect(await requestQuit(), isFalse);
    var asked = 0;
    AppChannel.listen(onQuitRequested: () async => asked++);
    await Future<void>.delayed(Duration.zero);
    expect(asked, 0);
  });
}
