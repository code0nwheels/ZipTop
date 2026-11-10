import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_config.dart';
import '../../core/api/auth_api.dart';
import '../../core/auth/token_store.dart';

/// Device-code pairing: show a code, poll until it is activated on the web,
/// then keep the token. A code that expires is replaced automatically.
class LoginController extends ChangeNotifier {
  LoginController({
    required this.api,
    required this.config,
    required this.tokens,
    required this.onPaired,
  });

  static const pollInterval = Duration(milliseconds: 2500);

  final AuthApi api;
  final ApiConfig config;
  final TokenStore tokens;
  final VoidCallback onPaired;

  String? _code;
  String? _linkUrl;
  int _expiresIn = 0;
  String? _error;
  Timer? _pollTimer;
  Timer? _expiryTimer;
  Timer? _restartTimer;
  bool _polling = false;
  bool _disposed = false;

  String? get code => _code;

  /// What the QR code encodes.
  String? get linkUrl => _linkUrl;
  int get expiresIn => _expiresIn;
  String? get error => _error;

  Future<void> start() async {
    _cancel();
    _error = null;
    _notify();
    try {
      final pairing = await api.generateCode();
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
