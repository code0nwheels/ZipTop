import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Holds the long-lived device token issued by pairing.
abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

/// Token kept in the OS credential vault (Credential Manager on Windows, the
/// Secret Service keyring on Linux, the login keychain on macOS).
class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              // The data protection keychain needs a keychain-access-groups
              // entitlement and so a provisioning profile, which a
              // self-signed build has none of. The legacy login keychain
              // needs neither. It asks once to allow access; builds signed
              // with the same certificate are then let in without asking.
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  static const _key = 'jwt_token';

  final FlutterSecureStorage _storage;
  String? _cached;
  bool _loaded = false;

  @override
  Future<String?> read() async {
    if (_loaded) return _cached;
    try {
      _cached = await _storage.read(key: _key);
    } catch (_) {
      _cached = null;
    }
    _loaded = true;
    return _cached;
  }

  @override
  Future<void> write(String token) async {
    _cached = token;
    _loaded = true;
    await _storage.write(key: _key, value: token);
  }

  @override
  Future<void> clear() async {
    _cached = null;
    _loaded = true;
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // Nothing stored, or the vault is unavailable; the in-memory copy is gone either way.
    }
  }
}

class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this._token]);

  String? _token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}
