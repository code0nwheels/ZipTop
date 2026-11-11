/// Native side only: the Dart API is lib/player/av_player.dart in the app,
/// which talks to the plugin over the `ziptop/avplayer` method channel.
library;

/// The method channel the plugin answers on.
const avPlayerChannel = 'ziptop/avplayer';
