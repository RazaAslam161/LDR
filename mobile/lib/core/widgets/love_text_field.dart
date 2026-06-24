import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/theme.dart';

/// An intimate, softly-glowing text input. Themed fill + ember focus border
/// (from the global InputDecorationTheme) plus a faint warm halo, with an
/// optional label above.
///
/// Usage: LoveTextField(label: 'Email', controller: _email, hint: 'you@…')
class LoveTextField extends StatelessWidget {
  const LoveTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.textAlign = TextAlign.start,
    this.autofocus = false,
    this.maxLength,
    this.inputFormatters,
    this.textStyle,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final TextAlign textAlign;
  final bool autofocus;
  final int? maxLength;
  final List<TextInputFormatter>? inputFormatters;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              label!,
              style: const TextStyle(fontSize: 12, color: MilesColors.taupe),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: MilesColors.ember.withValues(alpha: 0.07),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: TextField(
            controller: controller,
            obscureText: obscureText,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            onSubmitted: onSubmitted,
            textAlign: textAlign,
            autofocus: autofocus,
            maxLength: maxLength,
            inputFormatters: inputFormatters,
            autocorrect: false,
            style: textStyle ?? const TextStyle(color: MilesColors.cream50),
            decoration: InputDecoration(
              hintText: hint,
              counterText: '',
            ),
          ),
        ),
      ],
    );
  }
}
