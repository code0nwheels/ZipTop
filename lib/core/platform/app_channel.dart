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
/// Only the signed-in shell listens. When nothing does (the pairing screen,
/// after signing out) the request goes unanswered and the delegate quits at
/// once. Does nothing on other platforms.
class AppChannel {
  static const channel = MethodChannel('ziptop/app');

  /// Whether this runs at all; tests turn it on off macOS.
  @visibleForTesting
  static bool enabled = Platform.isMacOS;

  /// Calls [onQuitRequested] whenever the viewer asks macOS to quit ZipTop.
  ///
  /// The delegate is told straight away that the request was taken (`true`),
  /// not when [onQuitRequested] finishes: that may wait on the viewer
  /// answering "Keep ZipTop running?", or on the streams closing.
  static void listen({required Future<void> Function() onQuitRequested}) {
    if (!enabled) return;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'quitRequested') {
        throw MissingPluginException('ziptop/app has no ${call.method}');
      }
      unawaited(onQuitRequested());
      return true;
    });
  }

  static void stopListening() {
    if (!enabled) return;
    channel.setMethodCallHandler(null);
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
