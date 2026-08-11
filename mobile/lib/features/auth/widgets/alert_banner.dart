import 'package:flutter/material.dart';

import 'package:miles/core/ui/theme.dart';

enum AlertTone { error, info }

class AlertBanner extends StatelessWidget {
  const AlertBanner({
    required this.message, super.key,
    this.tone = AlertTone.error,
  });
  final String message;
  final AlertTone tone;

  @override
  Widget build(BuildContext context) {
    final color = tone == AlertTone.error
        ? const Color(0xFFEF6F58)
        : const Color(0xFF34D399);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MilesColors.tint(color, 0.1, over: MilesColors.night),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}
