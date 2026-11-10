import 'json.dart';

/// `POST api/auth/tv/generate-code`
class PairingCode {
  const PairingCode({required this.code, required this.expiresInSeconds});

  static PairingCode? tryParse(Json json) {
    final code = asString(json['code']);
    if (code == null || code.isEmpty) return null;
    return PairingCode(
      code: code,
      expiresInSeconds: asInt(json['expires_in_seconds']) ?? 900,
    );
  }

  final String code;
  final int expiresInSeconds;
}

/// `GET api/auth/tv/check-code/{code}`
class CodeStatus {
  const CodeStatus({required this.activated, this.token});

  factory CodeStatus.fromJson(Json json) => CodeStatus(
        activated: asBool(json['activated']) ?? false,
        token: asString(json['token']),
      );

  final bool activated;
  final String? token;
}

/// `GET api/account/me`
class AccountInfo {
  const AccountInfo({
    required this.username,
    this.createdAt,
    this.expirationDate,
    this.neverExpires = false,
    this.streamCount = 0,
  });

  factory AccountInfo.fromJson(Json json) => AccountInfo(
        username: asString(json['username']) ?? '',
        createdAt: asString(json['created_at']),
        expirationDate: asString(json['expiration_date']),
        neverExpires: asBool(json['never_expires']) ?? false,
        streamCount: asInt(json['stream_count']) ?? 0,
      );

  final String username;
  final String? createdAt;
  final String? expirationDate;
  final bool neverExpires;
  final int streamCount;
}

/// The account is at its concurrent-stream limit, or this session lost its slot.
class StreamLimitException implements Exception {
  const StreamLimitException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A request reached the server and was refused, or never reached it.
class ApiException implements Exception {
  const ApiException(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => message;
}

enum KickReason { watchTimeExceeded, other }

/// What a heartbeat told us about the session.
sealed class HeartbeatOutcome {
  const HeartbeatOutcome();
}

class HeartbeatOk extends HeartbeatOutcome {
  const HeartbeatOk();
}

/// The account-wide watch window is about to close; the viewer must confirm.
class HeartbeatWarn extends HeartbeatOutcome {
  const HeartbeatWarn(this.secondsRemaining);
  final int? secondsRemaining;
}

class HeartbeatKicked extends HeartbeatOutcome {
  const HeartbeatKicked(this.reason, this.message);
  final KickReason reason;
  final String message;
}
