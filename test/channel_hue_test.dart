import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziptop/ui/channel_hue.dart';

void main() {
  // Expected values come from streaming-platform's `hueOf` in
  // static/js/viewer/streams.js, run under node, so a channel's stripe is
  // the same colour in the web viewer and in ZipTop.
  const fromWeb = {
    'ESPN': 220,
    'CNN': 283,
    'Fox News': 244,
    'BBC One': 57,
    'Nickelodeon HD': 135,
    'Télé-Québec': 126,
    '🎬 Movies': 247,
    '': 0,
  };

  test('channelHue matches the web viewer', () {
    for (final entry in fromWeb.entries) {
      expect(channelHue(entry.key), entry.value, reason: entry.key);
    }
  });

  test('channelStripe is hsl(h 55% 58%)', () {
    final hsl = HSLColor.fromColor(channelStripe('ESPN'));
    expect(hsl.hue, closeTo(220, 1));
    expect(hsl.saturation, closeTo(0.55, 0.01));
    expect(hsl.lightness, closeTo(0.58, 0.01));
  });
}
