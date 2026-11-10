import '../models/playback.dart';
import 'api_client.dart';

/// Device-code pairing and account info.
class AuthApi {
  AuthApi(this._client);

  final ApiClient _client;

  Future<PairingCode> generateCode() async {
    final res = await _client.post('api/auth/tv/generate-code');
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
