import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_config.dart';
import '../../core/api/auth_api.dart';
import '../../core/auth/device_description.dart';
import '../../core/auth/token_store.dart';
import '../../core/platform/browser.dart';

/// Device-code pairing: get a code, poll until it is approved on the web,
/// then keep the token. A code that expires is replaced automatically.
///
/// The code is approved either in the browser on this computer
/// ([openBrowser] opens the approval page with the code filled in) or on
/// another device, by typing the code or scanning the QR code.
class LoginController extends ChangeNotifier {
  LoginController({
    required this.api,
    required this.config,
    required this.tokens,
    required this.onPaired,
    this.device,
    Future<bool> Function(String url)? browser,
  }) : _browser = browser ?? openInBrowser;

  static const pollInterval = Duration(milliseconds: 2500);

  final AuthApi api;
  final ApiConfig config;
  final TokenStore tokens;
  final VoidCallback onPaired;

  /// Sent with each code request, so the approval page can say what is
  /// asking to be signed in.
  final DeviceDescription? device;
  final Future<bool> Function(String url) _browser;

  String? _code;
  String? _linkUrl;
  int _expiresIn = 0;
  String? _error;
  Timer? _pollTimer;
  Timer? _expiryTimer;
  Timer? _restartTimer;
  bool _polling = false;
  bool _disposed = false;
  bool _browserOpened = false;

  String? get code => _code;

  /// What the QR code encodes.
  String? get linkUrl => _linkUrl;
  int get expiresIn => _expiresIn;
  String? get error => _error;

  /// True once the approval page was opened in the browser here, until the
  /// code is replaced.
  bool get browserOpened => _browserOpened;

  /// Opens the approval page for the current code in the default browser.
  Future<void> openBrowser() async {
    final link = _linkUrl;
    if (link == null) return;
    final opened = await _browser(link);
    if (_disposed || link != _linkUrl) return;
    _browserOpened = opened;
    _error = opened ? null : "Couldn't open your browser. Copy the link, or use the code below.";
    _notify();
  }

  Future<void> start() async {
    _cancel();
    _error = null;
    _browserOpened = false;
    _notify();
    try {
      final pairing = await api.generateCode(device: device);
      if (_disposed) return;
      _code = pairing.code;
      _linkUrl = config.linkUrl(pairing.code);
      _expiresIn = pairing.expiresInSeconds;
      _notify();
      _pollTimer = Timer.periodic(pollInterval, (_) => _poll(pairing.code));
      _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } catch (e) {
      if (_disposed) return;
      _code = null;
      _linkUrl = null;
      _error = e.toString();
      _notify();
    }
  }

  Future<void> _poll(String code) async {
    if (_polling) return;
    _polling = true;
    try {
      final status = await api.checkCode(code);
      final token = status.token;
      if (!_disposed && code == _code && status.activated && token != null) {
        _cancel();
        await tokens.write(token);
        if (!_disposed) onPaired();
      }
    } catch (_) {
      // Keep polling through network blips.
    } finally {
      _polling = false;
    }
  }

  void _tick() {
    _expiresIn--;
    if (_expiresIn > 0) {
      _notify();
      return;
    }
    _cancel();
    _expiresIn = 0;
    _error = 'Code expired. Getting a new one…';
    _notify();
    _restartTimer = Timer(const Duration(seconds: 2), start);
  }

  void _cancel() {
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    _restartTimer?.cancel();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel();
    super.dispose();
  }
}
