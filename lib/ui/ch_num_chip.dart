import 'package:flutter/material.dart';

import '../theme.dart';

/// Channel number in a pale-blue pill (`.ch-num` in the web viewer).
class ChNumChip extends StatelessWidget {
  const ChNumChip(this.number, {super.key, this.large = false});

  final Object number;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 10 : 7,
        vertical: large ? 3 : 1.5,
      ),
      decoration: const BoxDecoration(
        color: ZipColors.accentTint,
        borderRadius: ZipRadius.pillAll,
      ),
      child: Text(
        '$number',
        style: ZipText.mono(
          fontSize: large ? 15 : 12,
          fontWeight: FontWeight.w600,
          color: ZipColors.accentText,
          height: 1.25,
        ),
      ),
    );
  }
}
