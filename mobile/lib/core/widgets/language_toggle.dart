import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/ui/content_language.dart';
import 'package:miles/core/ui/theme.dart';

/// One half of the pill: the sliding thumb, and the slot each label sits in.
const double _slotWidth = 32;
const double _slotHeight = 26;

/// The compact EN / UR switch that sits in the AppBar of every screen whose
/// writing is bilingual.
///
/// A segmented pill rather than an icon button: an icon would need a tooltip to
/// say what it does, and a bare "EN" would not show that there is anything to
/// switch to. Both options are always visible, the live one is filled, and the
/// thumb slides — so the control explains itself without a word of chrome.
class LanguageToggle extends ConsumerWidget {
  const LanguageToggle({
    super.key,
    this.padding = const EdgeInsets.only(right: 6),
  });

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
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: MilesColors.cream50.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: MilesColors.cream50.withValues(alpha: 0.16),
              ),
            ),
            // Sized, not intrinsic. An Align with no widthFactor takes every
            // pixel it is offered, and in a bounded slot — a ListTile's
            // trailing, say — the pill stretched the full width of the row and
            // squeezed the text beside it down to one letter per line.
            child: SizedBox(
              width: values.length * _slotWidth,
              height: _slotHeight,
              child: Stack(
                children: [
                  AnimatedAlign(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment:
                        index == 0 ? Alignment.centerLeft : Alignment.centerRight,
                    child: Container(
                      width: _slotWidth,
                      height: _slotHeight,
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
                          width: _slotWidth,
                          height: _slotHeight,
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 220),
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: v == lang
                                    ? FontWeight.w700
                                    : FontWeight.w500,
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
      ),
    );
  }
}
