import 'package:flutter/material.dart';

import '../theme.dart';

/// A hairline ring with an accent arc, turning linearly.
class ZipSpinner extends StatelessWidget {
  const ZipSpinner({super.key, this.size = 36, this.stroke = 3});

  final double size;
  final double stroke;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CircularProgressIndicator(
        strokeWidth: stroke,
        color: ZipColors.accent,
        backgroundColor: ZipColors.lineHi,
        strokeCap: StrokeCap.round,
      ),
    );
  }
}
