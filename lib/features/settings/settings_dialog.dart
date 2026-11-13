import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/api/api_config.dart';
import '../../core/api/auth_api.dart';
import '../../core/models/playback.dart';
import '../../core/platform/browser.dart';
import '../../core/platform/startup.dart';
import '../../core/stores/catalog_store.dart';
import '../../core/stores/settings_store.dart';
import '../../theme.dart';
import '../../ui/focus_ring.dart';
import '../update/update_service.dart';
import 'pages/account_page.dart';
import 'pages/general_pages.dart';
import 'pages/player_pages.dart';

/// The pages of the settings dialog, in rail order.
enum SettingsSection {
  account(Icons.person_outline, 'Account', 'Your ZipStreams membership.'),
  playback(Icons.play_circle_outline, 'Playback', 'What plays when ZipTop opens, and at what quality.'),
  video(Icons.tv_outlined, 'Video', 'How the picture is drawn and decoded.'),
  audio(Icons.subtitles_outlined, 'Audio & captions', 'Sound output, languages and captions.'),
  advanced(Icons.tune, 'Advanced', 'Buffering and recovery. The defaults suit most connections.'),
  channels(Icons.view_list_outlined, 'Channels', 'The rows in the channel list.'),
  general(Icons.settings_outlined, 'General', 'Start-up, updates and version.');

  const SettingsSection(this.icon, this.label, this.description);

  final IconData icon;
  final String label;
  final String description;
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.settings,
    required this.setMaxBitrate,
    required this.catalog,
    required this.authApi,
    required this.config,
    required this.updates,
    required this.startup,
    required this.onUpdate,
    required this.onSignOut,
    this.initialSection = SettingsSection.account,
    this.packageInfo,
  });

  final SettingsStore settings;

  /// Caps the bitrate and reopens the playing stream at it.
  final Future<void> Function(int? bitsPerSecond) setMaxBitrate;
  final CatalogStore catalog;
  final AuthApi authApi;

  /// Where the website's account and plans pages are.
  final ApiConfig config;
  final UpdateService updates;
  final Autostart startup;

  /// An update was found; the caller offers it.
  final ValueChanged<UpdateInfo> onUpdate;
  final VoidCallback onSignOut;
  final SettingsSection initialSection;

  /// The installed app's details; read from the platform when null.
  final Future<PackageInfo>? packageInfo;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late SettingsSection _section = widget.initialSection;
  late Future<AccountInfo> _account = widget.authApi.accountInfo();
  String? _version;

  @override
  void initState() {
    super.initState();
    (widget.packageInfo ?? PackageInfo.fromPlatform()).then((info) {
      if (mounted) setState(() => _version = info.version);
    }, onError: (Object _) {});
  }

  Future<void> _openWeb(String page) async {
    final opened = await openInBrowser(widget.config.webUrl(page));
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text("Couldn't open your browser")));
    }
  }

  Widget _page() {
    final settings = widget.settings;
    return switch (_section) {
      SettingsSection.account => AccountPage(
          account: _account,
          plans: widget.catalog.planStatus,
          onRetry: () => setState(() => _account = widget.authApi.accountInfo()),
          onOpenWeb: _openWeb,
          onSignOut: widget.onSignOut,
        ),
      SettingsSection.playback =>
        PlaybackPage(settings: settings, setMaxBitrate: widget.setMaxBitrate),
      SettingsSection.video => VideoPage(settings: settings),
      SettingsSection.audio => AudioCaptionsPage(settings: settings),
      SettingsSection.advanced => AdvancedPage(settings: settings),
      SettingsSection.channels => ChannelsPage(settings: settings, catalog: widget.catalog),
      SettingsSection.general => GeneralPage(
          startup: widget.startup,
          updates: widget.updates,
          version: _version,
          onUpdate: widget.onUpdate,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(920, screen.width - 48),
        height: math.min(660, screen.height - 48),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Rail(
              selected: _section,
              version: _version,
              onSelected: (section) => setState(() => _section = section),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: ColoredBox(
                color: ZipColors.background,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(section: _section),
                    Expanded(
                      child: ListenableBuilder(
                        listenable: widget.settings,
                        builder: (context, _) => Scrollbar(
                          child: SingleChildScrollView(
                            key: PageStorageKey(_section),
                            padding: const EdgeInsets.fromLTRB(32, 4, 32, 32),
                            child: _page(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.section});

  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 16, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(section.label, style: text.titleLarge),
                const SizedBox(height: 4),
                Text(
                  section.description,
                  style: const TextStyle(fontSize: 13.5, color: ZipColors.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close (Esc)',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// The page list down the left side.
class _Rail extends StatelessWidget {
  const _Rail({required this.selected, required this.version, required this.onSelected});

  final SettingsSection selected;
  final String? version;
  final ValueChanged<SettingsSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 232,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 24, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              child: Text('Settings', style: Theme.of(context).textTheme.titleMedium),
            ),
            FocusTraversalGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final section in SettingsSection.values)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: _RailItem(
                        section: section,
                        selected: section == selected,
                        autofocus: section == selected,
                        onTap: () => onSelected(section),
                      ),
                    ),
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                version == null ? 'ZipTop' : 'ZipTop $version',
                style: ZipText.mono(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.section,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });

  final SettingsSection section;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: ZipTappable(
        autofocus: autofocus,
        onTap: onTap,
        borderRadius: ZipRadius.smAll,
        color: selected ? ZipColors.selected : Colors.transparent,
        hoverColor: selected ? ZipColors.selected : ZipColors.hover,
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              AnimatedContainer(
                duration: ZipMotion.fast,
                width: 3,
                height: selected ? 18 : 0,
                margin: const EdgeInsets.only(right: 9),
                decoration: const BoxDecoration(
                  color: ZipColors.accent,
                  borderRadius: ZipRadius.pillAll,
                ),
              ),
              Icon(
                section.icon,
                size: 20,
                color: selected ? ZipColors.accentText : ZipColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  section.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected ? ZipColors.text : ZipColors.textSecondary,
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
