import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/platform/startup.dart';
import '../../../core/platform/tray.dart';
import '../../../core/stores/catalog_store.dart';
import '../../../core/stores/settings_store.dart';
import '../../../theme.dart';
import '../../../ui/status_badge.dart';
import '../../update/update_service.dart';
import '../categories_dialog.dart';
import '../settings_widgets.dart';

/// The channel rows: which show, their order, and the Recent row.
class ChannelsPage extends StatelessWidget {
  const ChannelsPage({super.key, required this.settings, required this.catalog});

  final SettingsStore settings;
  final CatalogStore catalog;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'Categories',
          footer: 'Saved to your account, so they apply on your other devices too.',
          children: [
            SettingsRow(
              leading: const StatusIcon(Icons.view_list_outlined, tone: BadgeTone.accent),
              title: 'Manage categories',
              description: 'Show, hide and reorder the rows in the channel list.',
              trailing: const Icon(Icons.chevron_right, color: ZipColors.textMuted),
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => CategoriesDialog(catalog: catalog),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'On this computer',
          children: [
            SettingsSwitchRow(
              title: 'Recent channels',
              description: 'Show a Recent row with the last '
                  '${SettingsStore.maxRecents} channels you watched.',
              value: settings.recentsEnabled,
              onChanged: (v) => settings.recentsEnabled = v,
            ),
          ],
        ),
      ],
    );
  }
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

/// Start-up, updates and version.
class GeneralPage extends StatefulWidget {
  const GeneralPage({
    super.key,
    required this.startup,
    required this.updates,
    required this.version,
    required this.onUpdate,
  });

  final Autostart startup;
  final UpdateService updates;

  /// The installed version, once known.
  final String? version;

  /// An update was found; the caller offers it.
  final ValueChanged<UpdateInfo> onUpdate;

  @override
  State<GeneralPage> createState() => _GeneralPageState();
}

class _GeneralPageState extends State<GeneralPage> {
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
      setState(() => _updateStatus = "You're on the latest version.");
    } catch (_) {
      if (mounted) setState(() => _updateStatus = 'No update information is available right now.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.updates.currentVersion;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'Start-up',
          children: [
            SettingsSwitchRow(
              title: _startAtSignInLabel,
              description: 'Open ZipTop in the $trayPlaceName when you '
                  '${Platform.isMacOS ? 'log in' : 'sign in'}, so scheduled '
                  'recordings are not missed.',
              value: _startAtSignIn ?? false,
              onChanged: _startAtSignIn == null ? null : _setStartAtSignIn,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Updates',
          children: [
            ValueListenableBuilder<UpdateInfo?>(
              valueListenable: widget.updates.available,
              builder: (context, update, _) {
                if (update != null) {
                  return SettingsRow(
                    leading: const StatusIcon(Icons.download_rounded, tone: BadgeTone.success),
                    title: 'ZipTop ${update.version} is available',
                    description: 'You have $current.',
                    trailing: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: ZipColors.success,
                        foregroundColor: ZipColors.page,
                      ),
                      onPressed: () => widget.onUpdate(update),
                      child: const Text('Update'),
                    ),
                  );
                }
                return SettingsRow(
                  leading: const StatusIcon(Icons.system_update_alt, tone: BadgeTone.neutral),
                  title: 'Check for updates',
                  description: _updateStatus ?? 'You have version $current.',
                  trailing: OutlinedButton(
                    onPressed: _checking ? null : _checkForUpdates,
                    child: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Check now'),
                  ),
                );
              },
            ),
          ],
        ),
        SettingsGroup(
          title: 'About',
          children: [
            SettingsFactRow('Version', widget.version ?? current),
            SettingsRow(
              title: 'Open-source licenses',
              description: 'The software ZipTop is built with.',
              trailing: const Icon(Icons.chevron_right, color: ZipColors.textMuted),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'ZipTop',
                applicationVersion: widget.version ?? current,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
