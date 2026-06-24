import 'package:flutter/material.dart';

class LabeledField extends StatelessWidget {
  const LabeledField({
    required this.label, required this.child, super.key,
    this.hint,
  });
  final String label;
  final Widget child;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0x80F5EFE6),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
