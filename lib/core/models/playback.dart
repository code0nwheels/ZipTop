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
    this.accessMode,
    this.planLabel,
    this.email,
    this.streamLimit,
  });

  factory AccountInfo.fromJson(Json json) => AccountInfo(
        username: asString(json['username']) ?? '',
        createdAt: asString(json['created_at']),
        expirationDate: asString(json['expiration_date']),
        neverExpires: asBool(json['never_expires']) ?? false,
        streamCount: asInt(json['stream_count']) ?? 0,
        accessMode: asString(json['access_mode']),
        planLabel: asString(json['plan_label']),
        email: asString(json['email']),
        streamLimit: asInt(json['stream_limit']),
      );

  final String username;
  final String? createdAt;
  final String? expirationDate;
  final bool neverExpires;
  final int streamCount;

  /// `full` (every channel) or `plans` (season plans only).
  final String? accessMode;

  /// The season plan's name, when [accessMode] is `plans`.
  final String? planLabel;
  final String? email;

  /// Streams at once; 0 means no limit.
  final int? streamLimit;

  /// Days until [expirationDate] (negative once past), or null when it never
  /// expires or the date is unknown.
  int? daysLeft(DateTime now) {
    if (neverExpires) return null;
    final date = expirationDate == null ? null : DateTime.tryParse(expirationDate!);
    if (date == null) return null;
    return date.difference(now).inHours ~/ 24;
  }
}

/// The account is at its concurrent-stream limit, or this session lost its slot.
class StreamLimitException implements Exception {
  const StreamLimitException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The account's plan doesn't include this channel (`not_entitled`).
class NotEntitledException implements Exception {
  const NotEntitledException([this.message = defaultMessage]);

  static const defaultMessage = "Your plan doesn't include this channel.";

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
