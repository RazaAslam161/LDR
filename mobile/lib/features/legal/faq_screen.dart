import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/legal/faq_text.dart';

/// The FAQ, in-app for the same reasons the terms are: it has to work with no
/// connection, and it must not throw the user into a browser an onlooker can
/// read later. Content lives in faq_text.dart; this screen only renders it.
class FaqScreen extends StatelessWidget {
  const FaqScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sections = milesFaq();
    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(title: const Text('FAQ')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            for (final section in sections) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 22, 4, 6),
                child: Text(
                  section.title.toUpperCase(),
                  style: const TextStyle(
                    color: MilesColors.taupe,
                    fontSize: 12,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final entry in section.entries) _FaqTile(entry: entry),
            ],
          ],
        ),
      ),
    );
  }
}

class _FaqTile extends StatelessWidget {
  const _FaqTile({required this.entry});

  final FaqEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MilesColors.hairline),
      ),
      // clipBehavior so the ripple respects the rounded corners.
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // ExpansionTile paints its own dividers from the ambient theme; a
        // transparent divider keeps the card's single hairline border as the
        // only line on screen.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text(
            entry.question,
            style: const TextStyle(
              color: MilesColors.cream50,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          iconColor: MilesColors.taupe,
          collapsedIconColor: MilesColors.taupe,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.answer,
              style: const TextStyle(
                color: MilesColors.taupe,
                fontSize: 14,
                height: 1.55,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
