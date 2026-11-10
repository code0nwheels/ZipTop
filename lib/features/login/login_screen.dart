import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../providers.dart';
import '../../theme.dart';
import '../../ui/zip_spinner.dart';
import 'login_controller.dart';

/// Pairing screen: a code to enter at the link page, or a QR code to scan.
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
      onPaired: widget.onPaired,
    )..start();
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
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final code = _controller.code;
            final link = _controller.linkUrl;
            final error = _controller.error;
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
                      'Link this computer',
                      style: text.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Go to ${config.linkDisplay} on any device and enter this code, '
                      'or scan the QR code.',
                      textAlign: TextAlign.center,
                      style: text.bodyLarge?.copyWith(color: ZipColors.textSecondary),
                    ),
                    const SizedBox(height: 28),
                    if (code == null && error == null)
                      const Padding(
                        padding: EdgeInsets.all(40),
                        child: ZipSpinner(size: 44),
                      ),
                    if (code != null && link != null)
                      Container(
                        padding: const EdgeInsets.all(28),
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
                                    fontSize: 52,
                                    fontWeight: FontWeight.w700,
                                    color: ZipColors.accentText,
                                  ).copyWith(letterSpacing: 6),
                                ),
                                const SizedBox(height: 8),
                                Text.rich(
                                  TextSpan(
                                    text: 'Expires in ',
                                    children: [
                                      TextSpan(
                                        text: _countdown(_controller.expiresIn),
                                        style: ZipText.mono(fontSize: 14),
                                      ),
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
                              child: QrImageView(data: link, size: 190),
                            ),
                          ],
                        ),
                      ),
                    if (error != null) ...[
                      const SizedBox(height: 20),
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
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
