import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/content_language.dart';
import 'package:miles/core/theme.dart';

/// The compact EN / UR switch that sits in the AppBar of every screen whose
/// writing is bilingual.
///
/// A segmented pill rather than an icon button: an icon would need a tooltip to
/// say what it does, and a bare "EN" would not show that there is anything to
/// switch to. Both options are always visible, the live one is filled, and the
/// thumb slides — so the control explains itself without a word of chrome.
class LanguageToggle extends ConsumerWidget {
  const LanguageToggle({super.key, this.padding = const EdgeInsets.only(right: 6)});

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lang = ref.watch(contentLanguageProvider);
    const values = ContentLanguage.values;
    final index = values.indexOf(lang);

    return Padding(
      padding: padding,
      child: Semantics(
        label: 'Content language, currently ${lang.label}',
        button: true,
        child: GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            ref.read(contentLanguageProvider.notifier).toggle();
          },
          child: Container(
            height: 30,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: MilesColors.cream50.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: MilesColors.cream50.withValues(alpha: 0.16),
              ),
            ),
            child: Stack(
              children: [
                AnimatedAlign(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: index == 0
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  child: Container(
                    width: 32,
                    height: 26,
                    decoration: BoxDecoration(
                      color: MilesColors.blush.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final v in values)
                      SizedBox(
                        width: 32,
                        height: 26,
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 220),
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight:
                                  v == lang ? FontWeight.w700 : FontWeight.w500,
                              color: MilesColors.cream50.withValues(
                                alpha: v == lang ? 1 : 0.5,
                              ),
                              decoration: TextDecoration.none,
                            ),
                            child: Text(v.short),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
