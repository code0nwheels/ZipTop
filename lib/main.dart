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
  MediaKit.ensureInitialized(libmpv: bundledLibmpv());
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
    // Started at sign-in: stay hidden until opened from the tray.
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

/// On Linux, the libmpv 0.42 built by linux/third_party/build_libmpv.sh and
/// installed next to the executable. Loading it by path keeps media_kit from
/// picking up an older system libmpv.so. Null elsewhere, or when the build
/// uses the system libmpv. (On macOS media_kit loads Mpv.framework from the
/// app bundle, where the build has put the 0.42 build; see macos/Podfile.)
String? bundledLibmpv() {
  if (!Platform.isLinux) return null;
  final path = p.join(p.dirname(Platform.resolvedExecutable), 'lib', 'libmpv.so.2');
  return File(path).existsSync() ? path : null;
}
