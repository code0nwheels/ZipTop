import 'dart:io';

import 'package:flutter/services.dart';

/// The macOS app delegate's side of quitting (macos/Runner/AppDelegate.swift).
///
/// Cmd+Q and the app menu's Quit don't close the window, so window_manager
/// never hears of them. The delegate cancels them and sends `quitRequested`
/// here instead, so ZipTop shuts down as it does when the window is closed.
/// Once it is ready, [allowTerminate] lets the next terminate through.
/// Does nothing on other platforms.
class AppChannel {
  static const _channel = MethodChannel('ziptop/app');

  /// Calls [onQuitRequested] whenever the viewer asks macOS to quit ZipTop.
  static void listen({required Future<void> Function() onQuitRequested}) {
    if (!Platform.isMacOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'quitRequested') await onQuitRequested();
    });
  }

  static void stopListening() {
    if (!Platform.isMacOS) return;
    _channel.setMethodCallHandler(null);
  }

  /// Lets the app terminate; call just before `windowManager.destroy()`.
  static Future<void> allowTerminate() async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>('allowTerminate');
    } on MissingPluginException {
      // An older runner without the channel quits anyway.
    }
  }
}
