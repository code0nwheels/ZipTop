import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/platform/startup.dart';
import 'core/stores/settings_store.dart';
import 'dvr/dvr_store.dart';
import 'providers.dart';
import 'theme.dart';

Future<void> main(List<String> args) async {
  final startHidden = args.contains(StartupRegistration.minimizedFlag);
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  final settings = await SettingsStore.load();
  final support = await getApplicationSupportDirectory();
  final dvrStore = await DvrStore.open(File(p.join(support.path, 'dvr.json')));
  final package = await PackageInfo.fromPlatform();

  const options = WindowOptions(
    size: Size(1280, 760),
    minimumSize: Size(900, 560),
    center: true,
    title: 'ZipTop',
    backgroundColor: ZipColors.background,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    // Started with Windows: stay hidden until opened from the tray.
    if (startHidden) return;
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        dvrStoreProvider.overrideWithValue(dvrStore),
        startHiddenProvider.overrideWithValue(startHidden),
        appVersionProvider.overrideWithValue(package.version),
      ],
      child: const ZipTopApp(),
    ),
  );
}
