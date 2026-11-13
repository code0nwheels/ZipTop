import 'package:flutter/material.dart';

import '../../../core/models/catalog.dart' show PlanStatus;
import '../../../core/models/playback.dart';
import '../../../theme.dart';
import '../../../ui/status_badge.dart';
import '../settings_widgets.dart';

/// Who is signed in, what their account holds, and signing out.
class AccountPage extends StatelessWidget {
  const AccountPage({
    super.key,
    required this.account,
    required this.plans,
    required this.onRetry,
    required this.onOpenWeb,
    required this.onSignOut,
  });

  final Future<AccountInfo> account;
  final PlanStatus? plans;
  final VoidCallback onRetry;

  /// Opens a page of the ZipStreams website, such as `account`.
  final ValueChanged<String> onOpenWeb;
  final VoidCallback onSignOut;

  /// Dates arrive as ISO text; show just the day.
  static String day(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[local.month - 1]} ${local.day}, ${local.year}';
  }

  /// What the account holds: every channel, or a season plan.
  static String planName(AccountInfo account) => account.accessMode == 'plans'
      ? (account.planLabel ?? 'Season plan')
      : 'All channels';

  /// Renewal is worth offering within two weeks of expiry, or on a plans
  /// account with no plan running or booked.
  static bool offerRenewal(AccountInfo account, PlanStatus? plans, DateTime now) {
    final days = account.daysLeft(now);
    if (days != null && days <= 14) return true;
    return account.accessMode == 'plans' &&
        plans != null &&
        plans.activePlans.isEmpty &&
        plans.nextPlan == null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AccountInfo>(
      future: account,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SettingsGroup(
            children: [
              SettingsRow(
                leading: const StatusIcon(Icons.cloud_off_outlined, tone: BadgeTone.danger),
                title: "Couldn't load account details",
                description: 'Check your connection and try again.',
                trailing: OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
              ),
            ],
          );
        }
        final account = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            account == null ? const _ProfileLoading() : _Profile(account, plans, onOpenWeb),
            if (account != null) _membership(account),
            SettingsGroup(
              title: 'This computer',
              children: [
                SettingsRow(
                  leading: const StatusIcon(Icons.logout, tone: BadgeTone.danger),
                  title: 'Sign out',
                  titleColor: ZipColors.dangerText,
                  description: 'Unlinks this computer from your account. Scheduled '
                      'recordings stop until you sign in again.',
                  trailing: OutlinedButton(
                    style: const ButtonStyle(
                      foregroundColor: WidgetStatePropertyAll(ZipColors.dangerText),
                    ),
                    onPressed: onSignOut,
                    child: const Text('Sign out'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _membership(AccountInfo account) {
    final days = account.daysLeft(DateTime.now());
    final limit = account.streamLimit;
    return SettingsGroup(
      title: 'Membership',
      children: [
        SettingsFactRow('Plan', planName(account)),
        ..._planFacts(),
        SettingsFactRow(
          'Expires',
          account.neverExpires ? 'Never' : day(account.expirationDate),
          badge: days == null
              ? null
              : days < 0
                  ? const StatusBadge('Expired', tone: BadgeTone.danger)
                  : days <= 14
                      ? StatusBadge(
                          days == 0 ? 'Today' : '$days day${days == 1 ? '' : 's'} left',
                          tone: BadgeTone.warn,
                        )
                      : null,
        ),
        SettingsFactRow('Member since', day(account.createdAt)),
        SettingsFactRow(
          'Streams open now',
          limit == null || limit <= 0
              ? '${account.streamCount}'
              : '${account.streamCount} of $limit',
        ),
      ],
    );
  }

  /// A row per season plan running now; else the next one booked, or the
  /// one that ended last.
  List<Widget> _planFacts() {
    final plans = this.plans;
    if (plans == null) return const [];
    if (plans.activePlans.isNotEmpty) {
      return [
        for (final plan in plans.activePlans)
          SettingsFactRow(plan.name, 'Until ${day(plan.endsAt)}'),
      ];
    }
    final next = plans.nextPlan;
    if (next != null) {
      return [SettingsFactRow('Next plan', '${next.name}, from ${day(next.startsAt)}')];
    }
    final last = plans.lastEnded;
    if (last != null) {
      return [SettingsFactRow('Last plan', '${last.name}, ended ${day(last.endsAt)}')];
    }
    return const [];
  }
}

class _Profile extends StatelessWidget {
  const _Profile(this.account, this.plans, this.onOpenWeb);

  final AccountInfo account;
  final PlanStatus? plans;
  final ValueChanged<String> onOpenWeb;

  @override
  Widget build(BuildContext context) {
    final name = account.username.trim();
    final email = account.email;
    final renew = AccountPage.offerRenewal(account, plans, DateTime.now());
    return _ProfileCard(
      avatar: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: ZipColors.accentText,
        ),
      ),
      name: SelectableText(
        name.isEmpty ? 'Your account' : name,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      detail: Text(
        email == null || email.isEmpty ? 'No email on file' : email,
        style: const TextStyle(fontSize: 13.5, color: ZipColors.textSecondary),
      ),
      badge: StatusBadge(AccountPage.planName(account), tone: BadgeTone.accent),
      actions: [
        if (renew)
          FilledButton(
            onPressed: () => onOpenWeb('pricing'),
            child: Text(account.accessMode == 'plans' ? 'See plans' : 'Renew'),
          ),
        OutlinedButton.icon(
          onPressed: () => onOpenWeb('account'),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('Manage account'),
        ),
      ],
    );
  }
}

class _ProfileLoading extends StatelessWidget {
  const _ProfileLoading();

  @override
  Widget build(BuildContext context) {
    return const _ProfileCard(
      avatar: SizedBox.shrink(),
      name: SettingsPlaceholder(width: 160, height: 16),
      detail: Padding(
        padding: EdgeInsets.only(top: 4),
        child: SettingsPlaceholder(width: 200),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.avatar,
    required this.name,
    required this.detail,
    this.badge,
    this.actions = const [],
  });

  final Widget avatar;
  final Widget name;
  final Widget detail;
  final Widget? badge;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: ZipSpace.s5),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: ZipColors.surface,
        borderRadius: ZipRadius.lgAll,
        border: Border.all(color: ZipColors.line),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: ZipColors.accentDim, shape: BoxShape.circle),
            child: avatar,
          ),
          const SizedBox(width: ZipSpace.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: name),
                    if (badge != null) ...[const SizedBox(width: 10), badge!],
                  ],
                ),
                const SizedBox(height: 2),
                detail,
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: ZipSpace.s4),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}
