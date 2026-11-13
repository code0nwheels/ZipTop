import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../ui/zip_spinner.dart';
import 'login_controller.dart';

/// Sign-in: approve this computer in the browser here, or on another device
/// with the code or the QR code.
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

  String _countdown(int seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(apiConfigProvider);
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
                constraints: const BoxConstraints(maxWidth: 760),
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
                        if (code == null) ...[
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _controller.start,
                            child: const Text('Try again'),
                          ),
                        ],
                      ],
                      if (code != null && link != null) ...[
                        const SizedBox(height: 36),
                        Text(
                          'Or sign in from another device',
                          style: text.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Go to ${config.linkDisplay} on your phone or tablet and enter this code, '
                          'or scan the QR code.',
                          textAlign: TextAlign.center,
                          style: text.bodyMedium?.copyWith(color: ZipColors.textSecondary),
                        ),
                        const SizedBox(height: 16),
                        _CodeCard(
                          code: code,
                          link: link,
                          expiresIn: _countdown(_controller.expiresIn),
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

/// The code, its countdown, a copyable link and the QR code, for signing in
/// from another device.
class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code, required this.link, required this.expiresIn});

  final String code;
  final String link;
  final String expiresIn;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: ZipColors.surface,
        borderRadius: ZipRadius.lgAll,
        border: Border.all(color: ZipColors.line),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 40,
        runSpacing: 24,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                code,
                style: ZipText.mono(
                  fontSize: 44,
                  fontWeight: FontWeight.w700,
                  color: ZipColors.accentText,
                ).copyWith(letterSpacing: 6),
              ),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(
                  text: 'Expires in ',
                  children: [
                    TextSpan(text: expiresIn, style: ZipText.mono(fontSize: 14)),
                  ],
                ),
                style: text.bodyMedium?.copyWith(color: ZipColors.textMuted),
              ),
              const SizedBox(height: 16),
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
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: ZipRadius.mdAll,
            ),
            child: QrImageView(data: link, size: 160),
          ),
        ],
      ),
    );
  }
}
