import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/api/api_config.dart';
import '../../core/api/auth_api.dart';
import '../../core/models/catalog.dart' show PlanStatus;
import '../../core/models/playback.dart';
import '../../core/platform/browser.dart';
import '../../core/platform/startup.dart';
import '../../core/platform/tray.dart';
import '../../core/stores/catalog_store.dart';
import '../../core/stores/settings_store.dart';
import '../../theme.dart';
import '../update/update_service.dart';
import 'categories_dialog.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.settings,
    required this.catalog,
    required this.authApi,
    required this.config,
    required this.updates,
    required this.startup,
    required this.onUpdate,
    required this.onSignOut,
  });

  final SettingsStore settings;
  final CatalogStore catalog;
  final AuthApi authApi;

  /// Where the website's account and plans pages are.
  final ApiConfig config;
  final UpdateService updates;
  final Autostart startup;

  /// An update was found; the caller offers it.
  final ValueChanged<UpdateInfo> onUpdate;
  final VoidCallback onSignOut;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

/// What the start-at-sign-in switch is called on this platform.
String get _startAtSignInLabel => Platform.isMacOS
    ? 'Open at login'
    : Platform.isLinux
        ? 'Start when I sign in'
        : 'Start with Windows';
String get _startUpSettingName => Platform.isMacOS
    ? 'open-at-login'
    : Platform.isLinux
        ? 'start-at-sign-in'
        : 'Windows start-up';

class _SettingsDialogState extends State<SettingsDialog> {
  late final Future<AccountInfo> _account = widget.authApi.accountInfo();
  late final Future<PackageInfo> _package = PackageInfo.fromPlatform();
  bool? _startAtSignIn;
  bool _checking = false;
  String? _updateStatus;

  @override
  void initState() {
    super.initState();
    widget.startup.isEnabled().then((enabled) {
      if (mounted) setState(() => _startAtSignIn = enabled);
    });
  }

  Future<void> _setStartAtSignIn(bool enabled) async {
    final ok = await widget.startup.setEnabled(enabled);
    if (!mounted) return;
    setState(() => _startAtSignIn = ok ? enabled : _startAtSignIn);
    if (!ok) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text("Couldn't change the $_startUpSettingName setting")));
    }
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _checking = true;
      _updateStatus = null;
    });
    try {
      final update = await widget.updates.check();
      if (!mounted) return;
      if (update != null) {
        widget.onUpdate(update);
        return;
      }
      setState(() => _updateStatus = 'ZipTop is up to date.');
    } catch (_) {
      if (mounted) setState(() => _updateStatus = 'No update information is available right now.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Dates arrive as ISO text; show just the day.
  String _day(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  /// What the account holds: every channel, or a season plan.
  String _planName(AccountInfo account) => account.accessMode == 'plans'
      ? (account.planLabel ?? 'Season plan')
      : 'All channels';

  /// A row per season plan running now; else the next one booked, or the
  /// one that ended last.
  List<Widget> _planFacts(PlanStatus? plans) {
    if (plans == null) return const [];
    if (plans.activePlans.isNotEmpty) {
      return [
        for (final plan in plans.activePlans) _Fact(plan.name, 'until ${_day(plan.endsAt)}'),
      ];
    }
    final next = plans.nextPlan;
    if (next != null) return [_Fact('Next plan', '${next.name} from ${_day(next.startsAt)}')];
    final last = plans.lastEnded;
    if (last != null) return [_Fact('Last plan', '${last.name}, ended ${_day(last.endsAt)}')];
    return const [];
  }

  /// Renewal is worth offering within two weeks of expiry, or on a plans
  /// account with no plan running or booked.
  bool _offerRenewal(AccountInfo account, PlanStatus? plans) {
    final days = account.daysLeft(DateTime.now());
    if (days != null && days <= 14) return true;
    return account.accessMode == 'plans' &&
        plans != null &&
        plans.activePlans.isEmpty &&
        plans.nextPlan == null;
  }

  Future<void> _openWeb(String page) async {
    final opened = await openInBrowser(widget.config.webUrl(page));
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text("Couldn't open your browser")));
    }
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
                  final plans = widget.catalog.planStatus;
                  return Column(
                    children: [
                      _Fact('Username', account.username),
                      _Fact('Plan', _planName(account)),
                      ..._planFacts(plans),
                      _Fact('Member since', _day(account.createdAt)),
                      _Fact(
                        'Expires',
                        account.neverExpires ? 'Never' : _day(account.expirationDate),
                      ),
                      _Fact('Email', account.email ?? 'Not set'),
                      _Fact('Streams open now', '${account.streamCount}'),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            if (_offerRenewal(account, plans))
                              FilledButton(
                                onPressed: () => _openWeb('pricing'),
                                child: Text(account.accessMode == 'plans' ? 'See plans' : 'Renew'),
                              ),
                            OutlinedButton.icon(
                              onPressed: () => _openWeb('account'),
                              icon: const Icon(Icons.open_in_new, size: 18),
                              label: const Text('Manage account'),
                            ),
                          ],
                        ),
                      ),
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
              const _Section('This computer'),
              SwitchListTile(
                title: Text(_startAtSignInLabel),
                subtitle: Text(
                  'Open ZipTop in the $trayPlaceName when you '
                  '${Platform.isMacOS ? 'log in' : 'sign in'}, so scheduled '
                  'recordings are not missed',
                ),
                value: _startAtSignIn ?? false,
                onChanged: _startAtSignIn == null ? null : _setStartAtSignIn,
              ),
              if (widget.updates.available.value case final update?)
                ListTile(
                  leading: const Icon(Icons.download_rounded, color: ZipColors.success),
                  title: Text('ZipTop ${update.version} is available'),
                  subtitle: Text('You have ${widget.updates.currentVersion}'),
                  trailing: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: ZipColors.success,
                      foregroundColor: ZipColors.page,
                    ),
                    onPressed: () => widget.onUpdate(update),
                    child: const Text('Update'),
                  ),
                  onTap: () => widget.onUpdate(update),
                )
              else
                ListTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: const Text('Check for updates'),
                  subtitle: _updateStatus == null ? null : Text(_updateStatus!),
                  trailing: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: _checking ? null : _checkForUpdates,
                ),
              const Divider(height: 24),
              ListTile(
                leading: const Icon(Icons.logout, color: ZipColors.danger),
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
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
      child: Text(title, style: ZipText.label),
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
