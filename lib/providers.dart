import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/api/api_client.dart';
import 'core/api/api_config.dart';
import 'core/api/auth_api.dart';
import 'core/api/streams_api.dart';
import 'core/api/streams_v2_api.dart';
import 'core/auth/auth_events.dart';
import 'core/auth/token_store.dart';
import 'core/platform/startup.dart';
import 'core/platform/window_placement.dart';
import 'core/session/playback_session.dart';
import 'core/stores/catalog_store.dart';
import 'core/stores/guide_repository.dart';
import 'core/stores/settings_store.dart';
import 'dvr/dvr_service.dart';
import 'dvr/dvr_store.dart';
import 'features/update/update_service.dart';

final apiConfigProvider = Provider<ApiConfig>((ref) => ApiConfig());

final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

final authEventsProvider = Provider<AuthEvents>((ref) {
  final events = AuthEvents();
  ref.onDispose(events.dispose);
  return events;
});

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(
    config: ref.watch(apiConfigProvider),
    tokens: ref.watch(tokenStoreProvider),
    events: ref.watch(authEventsProvider),
  ),
);

final authApiProvider = Provider<AuthApi>((ref) => AuthApi(ref.watch(apiClientProvider)));

final streamsApiProvider =
    Provider<StreamsApi>((ref) => StreamsApi(ref.watch(apiClientProvider)));

final streamsV2ApiProvider =
    Provider<StreamsV2Api>((ref) => StreamsV2Api(ref.watch(apiClientProvider)));

final catalogStoreProvider = Provider<CatalogStore>((ref) {
  final store = CatalogStore(ref.watch(streamsV2ApiProvider));
  ref.onDispose(store.dispose);
  return store;
});

final guideRepositoryProvider = Provider<GuideRepository>((ref) {
  final repository = GuideRepository(ref.watch(streamsV2ApiProvider));
  ref.onDispose(repository.dispose);
  return repository;
});

/// True when ZipTop was started with `--minimized` (start at sign-in).
final startHiddenProvider = Provider<bool>((ref) => false);

/// Remembers the main window's place; set up in main() before the window shows.
final windowPlacementProvider = Provider<WindowPlacement>(
  (ref) => throw UnimplementedError('windowPlacementProvider is overridden in main()'),
);

/// This build's version, read before the app starts.
final appVersionProvider = Provider<String>((ref) => '0.0.0');

/// Start-at-sign-in: the Run key on Windows, an XDG autostart entry on Linux.
final startupRegistrationProvider = Provider<Autostart>((ref) => Autostart());

final updateServiceProvider = Provider<UpdateService>((ref) {
  final service = UpdateService(
    settings: ref.watch(settingsStoreProvider),
    currentVersion: ref.watch(appVersionProvider),
  );
  ref.onDispose(service.available.dispose);
  return service;
});

/// One count of who is using each stream, shared by the player, multiview
/// and recordings.
final streamSlotsProvider = Provider<StreamSlots>((ref) => StreamSlots());

/// Loaded before the app starts and supplied through a ProviderScope override.
final dvrStoreProvider = Provider<DvrStore>(
  (ref) => throw StateError('dvrStoreProvider must be overridden in main()'),
);

final dvrServiceProvider = Provider<DvrService>((ref) {
  final service = DvrService(
    store: ref.watch(dvrStoreProvider),
    api: ref.watch(streamsApiProvider),
    config: ref.watch(apiConfigProvider),
    guide: ref.watch(guideRepositoryProvider),
    slots: ref.watch(streamSlotsProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Loaded before the app starts and supplied through a ProviderScope override.
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => throw StateError('settingsStoreProvider must be overridden in main()'),
);
