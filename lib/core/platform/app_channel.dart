import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The macOS app delegate's side of quitting (macos/Runner/AppDelegate.swift).
///
/// Cmd+Q and the app menu's Quit don't close the window, so window_manager
/// never hears of them. The delegate cancels them and sends `quitRequested`
/// here instead, so ZipTop shuts down as it does when the window is closed.
/// Once it is ready, [allowTerminate] lets the next terminate through.
///
/// Every request gets an answer: `true` when the signed-in shell takes it,
/// `false` when nothing does (the pairing screen, after signing out), and
/// the delegate then quits at once. Flutter doesn't answer for a channel
/// with no handler: it holds the message until one is set, which swallowed
/// quits on the pairing screen and delivered them later, after signing in.
/// So [install] sets the handler for the app's whole life, and the shell
/// only comes and goes through [listen] and [stopListening].
/// Does nothing on other platforms.
class AppChannel {
  static const channel = MethodChannel('ziptop/app');

  /// Whether this runs at all; tests turn it on off macOS.
  @visibleForTesting
  static bool enabled = Platform.isMacOS;

  static Future<void> Function()? _onQuitRequested;

  /// Answers the delegate from now on. Call once, at start-up.
  static void install() {
    if (!enabled) return;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'quitRequested') {
        throw MissingPluginException('ziptop/app has no ${call.method}');
      }
      final onQuitRequested = _onQuitRequested;
      if (onQuitRequested == null) return false;
      unawaited(onQuitRequested());
      return true;
    });
  }

  /// Calls [onQuitRequested] whenever the viewer asks macOS to quit ZipTop,
  /// until [stopListening].
  ///
  /// The delegate is told straight away that the request was taken (`true`),
  /// not when [onQuitRequested] finishes: that may wait on the viewer
  /// answering "Keep ZipTop running?", or on the streams closing.
  static void listen({required Future<void> Function() onQuitRequested}) {
    _onQuitRequested = onQuitRequested;
  }

  static void stopListening() {
    _onQuitRequested = null;
  }

  /// Lets the app terminate; call just before `windowManager.destroy()`.
  static Future<void> allowTerminate() async {
    if (!enabled) return;
    try {
      await channel.invokeMethod<void>('allowTerminate');
    } on MissingPluginException {
      // An older runner without the channel quits anyway.
    }
  }
}
