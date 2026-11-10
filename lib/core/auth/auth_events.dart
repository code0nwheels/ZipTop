import 'dart:async';

/// Account-level events raised by the API client for the whole app to react to.
sealed class AuthEvent {
  const AuthEvent();
}

/// The token was rejected (revoked). The stored token has already been cleared.
class Unauthorized extends AuthEvent {
  const Unauthorized();
}

/// The token is valid but the account cannot be used right now.
class AccountBlocked extends AuthEvent {
  const AccountBlocked({required this.expired, required this.inactive});
  final bool expired;
  final bool inactive;
}

class AuthEvents {
  final _controller = StreamController<AuthEvent>.broadcast();

  Stream<AuthEvent> get stream => _controller.stream;

  void emit(AuthEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  void dispose() => _controller.close();
}
