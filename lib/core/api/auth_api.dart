import '../auth/device_description.dart';
import '../models/playback.dart';
import 'api_client.dart';

/// Device-code pairing, this device's record on the server, and account info.
class AuthApi {
  AuthApi(this._client);

  final ApiClient _client;

  /// A pairing code. [device] says what is asking, for the approval page and
  /// the account's list of signed-in devices; a server that predates that
  /// ignores it.
  Future<PairingCode> generateCode({DeviceDescription? device}) async {
    final res = await _client.post('api/auth/tv/generate-code', data: device?.toJson());
    final code = res.ok && res.json != null ? PairingCode.tryParse(res.json!) : null;
    if (code == null) {
      throw ApiException(
        res.errorMessage ?? 'Could not get a pairing code (${res.statusCode})',
        status: res.statusCode,
      );
    }
    return code;
  }

  Future<CodeStatus> checkCode(String code) async {
    final res = await _client.get('api/auth/tv/check-code/${Uri.encodeComponent(code)}');
    final json = res.json;
    if (!res.ok || json == null) {
      throw ApiException('Code check failed (${res.statusCode})', status: res.statusCode);
    }
    return CodeStatus.fromJson(json);
  }

  /// Tells the server what this device is now (name, OS, version). Returns a
  /// replacement token when the server issued one: a token from before the
  /// server kept a list of signed-in devices is swapped for one that puts
  /// this computer on that list. Null otherwise, including from a server
  /// that doesn't know this call.
  Future<String?> describeDevice(DeviceDescription device) async {
    final res = await _client.put('api/auth/device', data: device.toJson());
    if (!res.ok) return null;
    final token = res.json?['token'];
    return token is String && token.isNotEmpty ? token : null;
  }

  /// Signs this device out on the server, so its token stops working. Call it
  /// before forgetting the token. Throws when the server can't be reached.
  Future<void> logout() async {
    await _client.post('api/auth/logout');
  }

  /// [logout], given at most [timeout] and never throwing: signing out on
  /// this computer goes ahead whether or not the server heard about it.
  Future<void> logoutQuietly({Duration timeout = const Duration(seconds: 3)}) async {
    try {
      await logout().timeout(timeout);
    } catch (_) {
      // Offline or slow: the token is forgotten here all the same.
    }
  }

  Future<AccountInfo> accountInfo() async {
    final res = await _client.get('api/account/me');
    final json = res.json;
    if (!res.ok || json == null) {
      throw ApiException(
        res.errorMessage ?? 'Could not load account (${res.statusCode})',
        status: res.statusCode,
      );
    }
    return AccountInfo.fromJson(json);
  }
}
