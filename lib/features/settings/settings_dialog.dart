import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/api/auth_api.dart';
import '../../core/models/playback.dart';
import '../../core/stores/catalog_store.dart';
import '../../core/stores/settings_store.dart';
import '../../theme.dart';
import 'categories_dialog.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.settings,
    required this.catalog,
    required this.authApi,
    required this.onSignOut,
  });

  final SettingsStore settings;
  final CatalogStore catalog;
  final AuthApi authApi;
  final VoidCallback onSignOut;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final Future<AccountInfo> _account = widget.authApi.accountInfo();
  late final Future<PackageInfo> _package = PackageInfo.fromPlatform();

  /// Dates arrive as ISO text; show just the day.
  String _day(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final settings = widget.settings;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 12, 8),
                child: Row(
                  children: [
                    Text('Settings', style: text.headlineSmall),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const _Section('Account'),
              FutureBuilder<AccountInfo>(
                future: _account,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const ListTile(
                      dense: true,
                      title: Text("Couldn't load account details"),
                    );
                  }
                  final account = snapshot.data;
                  if (account == null) {
                    return const ListTile(dense: true, title: Text('Loading…'));
                  }
                  return Column(
                    children: [
                      _Fact('Username', account.username),
                      _Fact('Member since', _day(account.createdAt)),
                      _Fact(
                        'Expires',
                        account.neverExpires ? 'Never' : _day(account.expirationDate),
                      ),
                      _Fact('Streams open now', '${account.streamCount}'),
                    ],
                  );
                },
              ),
              const _Section('Playback'),
              SwitchListTile(
                title: const Text('Play last channel on start'),
                subtitle: const Text('Resume where you left off when ZipTop opens'),
                value: settings.playLastOnStart,
                onChanged: (v) => settings.playLastOnStart = v,
              ),
              SwitchListTile(
                title: const Text('Recent channels'),
                subtitle: const Text('Show a Recent row with the last 10 channels'),
                value: settings.recentsEnabled,
                onChanged: (v) => settings.recentsEnabled = v,
              ),
              const _Section('Channels'),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Manage categories'),
                subtitle: const Text('Show, hide and reorder rows. Saved to your account.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => CategoriesDialog(catalog: widget.catalog),
                ),
              ),
              const Divider(height: 24),
              ListTile(
                leading: const Icon(Icons.logout, color: ZipColors.offline),
                title: const Text('Sign out'),
                subtitle: const Text('Unlink this computer; you will need to pair again'),
                onTap: widget.onSignOut,
              ),
              FutureBuilder<PackageInfo>(
                future: _package,
                builder: (context, snapshot) => Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                  child: Text(
                    snapshot.hasData ? 'ZipTop ${snapshot.data!.version}' : 'ZipTop',
                    style: text.bodySmall?.copyWith(color: ZipColors.textMuted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: ZipColors.accent,
              letterSpacing: 1.1,
            ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: ZipColors.textSecondary)),
          ),
          SelectableText(value),
        ],
      ),
    );
  }
}
