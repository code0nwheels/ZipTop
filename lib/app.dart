import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'core/auth/auth_events.dart';
import 'features/login/login_screen.dart';
import 'features/shell/shell_screen.dart';
import 'providers.dart';
import 'theme.dart';

class ZipTopApp extends StatelessWidget {
  const ZipTopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZipTop',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const AppRoot(),
    );
  }
}

/// Chooses between pairing and the player, and reacts to account-level events.
class AppRoot extends ConsumerStatefulWidget {
  const AppRoot({super.key});

  @override
  ConsumerState<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<AppRoot> {
  bool? _signedIn;
  AccountBlocked? _blocked;
  StreamSubscription<AuthEvent>? _events;

  @override
  void initState() {
    super.initState();
    _events = ref.read(authEventsProvider).stream.listen(_onAuthEvent);
    unawaited(_loadToken());
  }

  Future<void> _loadToken() async {
    final token = await ref.read(tokenStoreProvider).read();
    // Started hidden but not paired: there is nothing to do in the tray.
    if (token == null && ref.read(startHiddenProvider)) await windowManager.show();
    if (mounted) setState(() => _signedIn = token != null);
  }

  void _onAuthEvent(AuthEvent event) {
    if (!mounted) return;
    switch (event) {
      case Unauthorized():
        // The token was revoked and has already been cleared.
        setState(() {
          _signedIn = false;
          _blocked = null;
        });
      case AccountBlocked():
        setState(() => _blocked = event);
    }
  }

  Future<void> _signOutBlocked() async {
    await ref.read(tokenStoreProvider).clear();
    ref.read(catalogStoreProvider).clear();
    if (mounted) {
      setState(() {
        _signedIn = false;
        _blocked = null;
      });
    }
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _blocked;
    if (blocked != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                blocked.expired ? 'Your account has expired' : 'Your account is inactive',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Renew or reactivate it on the ZipStreams website, then try again.',
                style: TextStyle(color: ZipColors.textSecondary),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton(
                    onPressed: () => setState(() => _blocked = null),
                    child: const Text('Try again'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _signOutBlocked,
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return switch (_signedIn) {
      null => const Scaffold(body: Center(child: CircularProgressIndicator())),
      false => LoginScreen(onPaired: () => setState(() => _signedIn = true)),
      true => ShellScreen(
          key: const ValueKey('shell'),
          onSignedOut: () => setState(() => _signedIn = false),
        ),
    };
  }
}
