import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ziptop/core/api/api_client.dart';
import 'package:ziptop/core/api/api_config.dart';
import 'package:ziptop/core/api/auth_api.dart';
import 'package:ziptop/core/api/streams_v2_api.dart';
import 'package:ziptop/core/auth/auth_events.dart';
import 'package:ziptop/core/auth/token_store.dart';
import 'package:ziptop/core/models/playback.dart';
import 'package:ziptop/core/platform/startup.dart';
import 'package:ziptop/core/stores/catalog_store.dart';
import 'package:ziptop/core/stores/settings_store.dart';
import 'package:ziptop/features/settings/settings_dialog.dart';
import 'package:ziptop/features/update/update_service.dart';
import 'package:ziptop/player/player_preferences.dart';
import 'package:ziptop/theme.dart';

class _FakeAuthApi implements AuthApi {
  @override
  Future<AccountInfo> accountInfo() async => const AccountInfo(
        username: 'viewer',
        email: 'viewer@example.com',
        neverExpires: true,
        streamCount: 1,
        streamLimit: 2,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUpdates implements UpdateService {
  @override
  final available = ValueNotifier<UpdateInfo?>(null);

  @override
  String get currentVersion => '1.2.0';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAutostart implements Autostart {
  bool enabled = false;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<bool> setEnabled(bool value) async {
    enabled = value;
    return true;
  }
}

void main() {
  late SettingsStore settings;
  late List<int?> caps;
  late int signOuts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await SettingsStore.load();
    caps = [];
    signOuts = 0;
  });

  Future<void> open(WidgetTester tester, {SettingsSection section = SettingsSection.account}) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: SettingsDialog(
            settings: settings,
            setMaxBitrate: (cap) async {
              caps.add(cap);
              settings.maxBitrate = cap;
            },
            catalog: CatalogStore(
              StreamsV2Api(
                ApiClient(config: ApiConfig(), tokens: MemoryTokenStore(), events: AuthEvents()),
              ),
            ),
            authApi: _FakeAuthApi(),
            config: ApiConfig(),
            updates: _FakeUpdates(),
            startup: _FakeAutostart(),
            onUpdate: (_) {},
            onSignOut: () => signOuts++,
            initialSection: section,
            packageInfo: Future.value(
              PackageInfo(appName: 'ZipTop', packageName: 'ziptop', version: '1.2.0', buildNumber: '1'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String current, String option) async {
    await tester.tap(find.text(current).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  testWidgets('every page opens from the rail', (tester) async {
    await open(tester);
    for (final section in SettingsSection.values) {
      await tester.tap(find.text(section.label).first);
      await tester.pumpAndSettle();
      expect(find.text(section.description), findsOneWidget, reason: section.label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the account page shows the account and signs out', (tester) async {
    await open(tester);
    expect(find.text('viewer'), findsOneWidget);
    expect(find.text('1 of 2'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
    expect(signOuts, 1);
  });

  testWidgets('video settings save as they change', (tester) async {
    await open(tester, section: SettingsSection.video);
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deinterlace'));
    await tester.pumpAndSettle();
    await choose(tester, 'Automatic', 'Off');
    final prefs = settings.playerPreferences;
    expect(prefs.fill, isTrue);
    expect(prefs.deinterlace, isTrue);
    expect(prefs.hardwareDecoding, HardwareDecoding.off);
  });

  testWidgets('default quality goes through the live player', (tester) async {
    await open(tester, section: SettingsSection.playback);
    await choose(tester, 'Best available', 'Medium (4 Mbps)');
    expect(caps, [4000000]);
    await choose(tester, 'Up to 4.5 Mbps', 'No limit');
    expect(settings.playerPreferences.tileMaxBitrate, isNull);
  });

  testWidgets('a cap picked on the player shows as custom', (tester) async {
    settings.maxBitrate = 6221600;
    await open(tester, section: SettingsSection.playback);
    expect(find.text('Custom (6.2 Mbps)'), findsOneWidget);
  });

  testWidgets('caption language waits for captions to be turned on', (tester) async {
    await open(tester, section: SettingsSection.audio);
    final language = find.widgetWithText(OutlinedButton, 'First available');
    expect(tester.widget<OutlinedButton>(language).onPressed, isNull);
    await tester.tap(find.text('Turn on captions automatically'));
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(language).onPressed, isNotNull);
    await choose(tester, 'First available', 'Spanish');
    expect(settings.playerPreferences.captionLanguage, 'es');
  });

  testWidgets('advanced buffer settings change and restore', (tester) async {
    await open(tester, section: SettingsSection.advanced);
    final restore = find.widgetWithText(OutlinedButton, 'Restore defaults');
    expect(tester.widget<OutlinedButton>(restore).onPressed, isNull);
    await choose(tester, '30 s (default)', '60 s');
    expect(settings.playerPreferences.bufferSeconds, 60);
    await tester.ensureVisible(restore);
    await tester.pumpAndSettle();
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(settings.playerPreferences.bufferSeconds, 30);
  });
}
