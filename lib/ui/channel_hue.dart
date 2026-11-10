import 'package:flutter/painting.dart';

/// Stable hue (0–359) for a channel name, so each channel keeps the same
/// stripe colour on every visit.
///
/// Port of `hueOf` in streaming-platform's `static/js/viewer/streams.js`:
/// `h = (h * 31 + codePoint) >>> 0; return h % 360`, so a channel gets the
/// same colour in the web viewer and here.
int channelHue(String name) {
  var h = 0;
  for (final cp in name.runes) {
    h = (h * 31 + cp) & 0xFFFFFFFF;
  }
  return h % 360;
}

/// The tile stripe colour: `hsl(h 55% 58%)`.
Color channelStripe(String name) =>
    HSLColor.fromAHSL(1, channelHue(name).toDouble(), 0.55, 0.58).toColor();
