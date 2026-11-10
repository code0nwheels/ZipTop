import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/api/api_client.dart';
import 'core/api/api_config.dart';
import 'core/api/auth_api.dart';
import 'core/api/streams_api.dart';
import 'core/api/streams_v2_api.dart';
import 'core/auth/auth_events.dart';
import 'core/auth/token_store.dart';
import 'core/stores/catalog_store.dart';

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
