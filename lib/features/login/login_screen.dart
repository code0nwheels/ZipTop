import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../ui/zip_spinner.dart';
import 'login_controller.dart';

/// Sign-in: approve this computer in the browser on this computer.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, required this.onPaired});

  final VoidCallback onPaired;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late final LoginController _controller;

  @override
  void initState() {
    super.initState();
    _controller = LoginController(
      api: ref.read(authApiProvider),
      config: ref.read(apiConfigProvider),
      tokens: ref.read(tokenStoreProvider),
      device: ref.read(deviceDescriptionProvider),
      onPaired: _paired,
    )..start();
  }

  /// Signed in: bring ZipTop back in front of the browser it was approved in.
  Future<void> _paired() async {
    try {
      await ref.read(windowPlacementProvider).show();
      await windowManager.focus();
    } catch (_) {
      // No window to raise (tests); signing in matters more.
    }
    widget.onPaired();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final code = _controller.code;
              final link = _controller.linkUrl;
              final error = _controller.error;
              final opened = _controller.browserOpened;
              return ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset('assets/logo.png', height: 72),
                      const SizedBox(height: 28),
                      Text(
                        'Sign in to ZipTop',
                        style: text.headlineMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        opened
                            ? 'Approve ZipTop in your browser. This window signs in by itself.'
                            : 'Sign in with your ZipStreams account in your web browser.',
                        textAlign: TextAlign.center,
                        style: text.bodyLarge?.copyWith(color: ZipColors.textSecondary),
                      ),
                      const SizedBox(height: 24),
                      if (code == null && error == null)
                        const Padding(
                          padding: EdgeInsets.all(40),
                          child: ZipSpinner(size: 44),
                        ),
                      if (code != null && link != null)
                        FilledButton.icon(
                          onPressed: _controller.openBrowser,
                          icon: const Icon(Icons.open_in_browser, size: 20),
                          label: Text(opened ? 'Open the browser again' : 'Sign in with your browser'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                            textStyle: text.titleMedium,
                          ),
                        ),
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          error,
                          textAlign: TextAlign.center,
                          style: text.bodyMedium?.copyWith(color: ZipColors.warnText),
                        ),
                        const SizedBox(height: 12),
                        if (code == null)
                          FilledButton(
                            onPressed: _controller.start,
                            child: const Text('Try again'),
                          )
                        else if (link != null)
                          // The browser wouldn't open: the link can still be
                          // pasted into one by hand.
                          OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: link));
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Link copied')),
                              );
                            },
                            icon: const Icon(Icons.link, size: 18),
                            label: const Text('Copy link'),
                          ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
